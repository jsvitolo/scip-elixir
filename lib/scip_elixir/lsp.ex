defmodule ScipElixir.LSP do
  @moduledoc """
  LSP server for scip-elixir using gen_lsp.

  Provides code intelligence by querying the SQLite index built
  by the compiler tracer.

  ## Capabilities

  - `textDocument/definition` — go to definition
  - `textDocument/references` — find all references
  - `textDocument/hover` — documentation on hover
  - `textDocument/documentSymbol` — symbols in current file
  - `workspace/symbol` — project-wide symbol search (FTS5)
  """

  use GenLSP

  alias GenLSP.Enumerations.{SymbolKind, TextDocumentSyncKind}

  alias GenLSP.Structures.{
    InitializeResult,
    ServerCapabilities,
    TextDocumentSyncOptions,
    SaveOptions,
    Location,
    Position,
    Range,
    Hover,
    MarkupContent,
    SymbolInformation,
    DocumentSymbol
  }

  alias GenLSP.Requests.{
    Initialize,
    TextDocumentDefinition,
    TextDocumentReferences,
    TextDocumentHover,
    TextDocumentDocumentSymbol,
    WorkspaceSymbol
  }

  alias GenLSP.Notifications.{
    Initialized,
    TextDocumentDidOpen,
    TextDocumentDidChange,
    TextDocumentDidSave,
    TextDocumentDidClose
  }

  require Logger

  @default_db_path ".scip-elixir/index.db"

  def start_link(args) do
    {opts, lsp_opts} = Keyword.split(args, [:db_path])

    GenLSP.start_link(__MODULE__, opts, lsp_opts)
  end

  # --- GenLSP Callbacks ---

  @impl true
  def init(lsp, opts) do
    db_path = Keyword.get(opts, :db_path, @default_db_path)
    {:ok, assign(lsp, db_path: db_path, store: nil, root_uri: nil, documents: %{})}
  end

  @impl true
  def handle_request(%Initialize{params: params}, lsp) do
    root_uri = params.root_uri

    # Open the SQLite index
    db_path = resolve_db_path(lsp.assigns.db_path, root_uri)

    store =
      try do
        {:ok, conn} = ScipElixir.Store.open(db_path)
        Logger.info("[scip-elixir] Opened index at #{db_path}")
        conn
      rescue
        e ->
          Logger.warning("[scip-elixir] Could not open index at #{db_path}: #{inspect(e)}")
          nil
      end

    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: false},
           change: TextDocumentSyncKind.full()
         },
         definition_provider: true,
         references_provider: true,
         hover_provider: true,
         document_symbol_provider: true,
         workspace_symbol_provider: true
       },
       server_info: %{name: "scip-elixir", version: "0.1.0"}
     }, assign(lsp, store: store, root_uri: root_uri)}
  end

  # --- textDocument/definition ---

  def handle_request(%TextDocumentDefinition{params: params}, lsp) do
    if lsp.assigns.store == nil do
      {:reply, nil, lsp}
    else
      uri = params.text_document.uri
      line = params.position.line
      col = params.position.character
      file = uri_to_path(uri)

      case resolve_and_find_definition(lsp, uri, file, line, col) do
        {:ok, location} -> {:reply, location, lsp}
        :error -> {:reply, nil, lsp}
      end
    end
  end

  # --- textDocument/references ---

  def handle_request(%TextDocumentReferences{params: params}, lsp) do
    if lsp.assigns.store == nil do
      {:reply, [], lsp}
    else
      uri = params.text_document.uri
      line = params.position.line
      col = params.position.character
      file = uri_to_path(uri)

      locations = resolve_and_find_references(lsp, uri, file, line, col)
      {:reply, locations, lsp}
    end
  end

  # --- textDocument/hover ---

  def handle_request(%TextDocumentHover{params: params}, lsp) do
    if lsp.assigns.store == nil do
      {:reply, nil, lsp}
    else
      uri = params.text_document.uri
      line = params.position.line
      col = params.position.character
      file = uri_to_path(uri)

      case resolve_and_hover(lsp, uri, file, line, col) do
        {:ok, hover} -> {:reply, hover, lsp}
        :error -> {:reply, nil, lsp}
      end
    end
  end

  # --- textDocument/documentSymbol ---

  def handle_request(%TextDocumentDocumentSymbol{params: params}, lsp) do
    if lsp.assigns.store == nil do
      {:reply, [], lsp}
    else
      uri = params.text_document.uri
      file = uri_to_path(uri)

      symbols =
        ScipElixir.Store.symbols_in_file(lsp.assigns.store, file)
        |> Enum.map(&symbol_to_document_symbol/1)

      {:reply, symbols, lsp}
    end
  end

  # --- workspace/symbol ---

  def handle_request(%WorkspaceSymbol{params: params}, lsp) do
    if lsp.assigns.store == nil do
      {:reply, [], lsp}
    else
      query = params.query

      if String.length(query) < 2 do
        {:reply, [], lsp}
      else
        symbols =
          ScipElixir.Store.search(lsp.assigns.store, fts5_query(query))
          |> Enum.map(fn sym -> symbol_to_symbol_info(sym, lsp.assigns) end)

        {:reply, symbols, lsp}
      end
    end
  end

  # Catch-all
  def handle_request(_request, lsp) do
    {:noreply, lsp}
  end

  # --- Notifications ---

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    if lsp.assigns.store do
      stats = ScipElixir.Store.stats(lsp.assigns.store)

      GenLSP.log(lsp, "[scip-elixir] Index loaded: #{stats.symbols} symbols, #{stats.refs} refs across #{stats.files} files")
    else
      GenLSP.warning(lsp, "[scip-elixir] No index found. Run: mix scip.index")
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    uri = params.text_document.uri
    text = params.text_document.text
    documents = Map.put(lsp.assigns.documents, uri, text)
    {:noreply, assign(lsp, documents: documents)}
  end

  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    uri = params.text_document.uri

    # Full sync mode — last content change has the full text
    text =
      case params.content_changes do
        [%{text: text} | _] -> text
        _ -> Map.get(lsp.assigns.documents, uri, "")
      end

    documents = Map.put(lsp.assigns.documents, uri, text)
    {:noreply, assign(lsp, documents: documents)}
  end

  def handle_notification(%TextDocumentDidSave{}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    uri = params.text_document.uri
    documents = Map.delete(lsp.assigns.documents, uri)
    {:noreply, assign(lsp, documents: documents)}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  @impl true
  def handle_info(_msg, lsp) do
    {:noreply, lsp}
  end

  # --- Private: Tree-sitter powered resolution ---

  # Get source code for a document (from open buffer or file)
  defp get_source(lsp, uri, file) do
    case Map.get(lsp.assigns.documents, uri) do
      nil -> File.read(file) |> elem(1)
      text -> text
    end
  end

  # Use tree-sitter to identify what's at cursor, then query the store
  defp resolve_symbol_at_cursor(source, line, col) do
    try do
      node = ScipElixir.TreeSitter.node_at_position(source, line, col)
      resolve_node(node, source)
    rescue
      _ -> nil
    end
  end

  # Resolve a tree-sitter node to a {module, name, arity} tuple
  defp resolve_node(%{kind: "alias", text: text}, _source) do
    # Module alias: MyApp.Router → look up as module
    {:module, text}
  end

  defp resolve_node(%{kind: "identifier", text: text, parent_kind: "dot"}, _source) do
    # Dot-accessed function: Module.function → need the full dot expression
    # text is just the function name part
    {:function_name, text}
  end

  defp resolve_node(%{kind: "identifier", text: text, parent_kind: parent}, _source)
       when parent in ["call", "arguments"] do
    {:function_name, text}
  end

  defp resolve_node(%{kind: "identifier", text: text}, _source) do
    {:identifier, text}
  end

  defp resolve_node(%{kind: "atom", text: ":" <> name}, _source) do
    {:atom, name}
  end

  defp resolve_node(_, _source), do: nil

  # --- Definition ---

  defp resolve_and_find_definition(lsp, uri, file, line, col) do
    store = lsp.assigns.store
    source = get_source(lsp, uri, file)

    # First try tree-sitter resolution
    case resolve_symbol_at_cursor(source, line, col) do
      {:module, mod_name} ->
        find_module_definition(store, mod_name, lsp.assigns)

      {:function_name, fn_name} ->
        # Try to find via ref at this line (has module context)
        case ScipElixir.Store.find_ref_at(store, file, line + 1) do
          %{target_module: mod, target_name: ^fn_name, target_arity: arity} ->
            find_function_definition(store, mod, fn_name, arity, lsp.assigns)

          %{target_module: mod} when not is_nil(mod) ->
            find_function_definition(store, mod, fn_name, nil, lsp.assigns)

          _ ->
            # Fallback: search by name across all modules
            search_definition_by_name(store, fn_name, lsp.assigns)
        end

      {:identifier, name} ->
        # Could be a local function call or variable
        case ScipElixir.Store.find_ref_at(store, file, line + 1) do
          %{target_module: mod, target_name: ^name, target_arity: arity} ->
            find_function_definition(store, mod, name, arity, lsp.assigns)

          _ ->
            search_definition_by_name(store, name, lsp.assigns)
        end

      _ ->
        # Fallback to line-based lookup
        fallback_definition(store, file, line + 1, lsp.assigns)
    end
  end

  defp find_module_definition(store, module, assigns) do
    # Try exact match first, then with "Elixir." prefix
    case ScipElixir.Store.find_symbol(store, nil, module, nil) do
      %{} = sym -> {:ok, symbol_to_location(sym, assigns)}
      nil ->
        case ScipElixir.Store.find_symbol(store, nil, "Elixir.#{module}", nil) do
          %{} = sym -> {:ok, symbol_to_location(sym, assigns)}
          nil -> :error
        end
    end
  end

  defp find_function_definition(store, module, name, arity, assigns) do
    case ScipElixir.Store.find_symbol(store, module, name, arity) do
      %{} = sym -> {:ok, symbol_to_location(sym, assigns)}
      nil -> :error
    end
  end

  defp search_definition_by_name(store, name, assigns) do
    case ScipElixir.Store.search(store, "#{name}*", 1) do
      [%{} = sym | _] -> {:ok, symbol_to_location(sym, assigns)}
      _ -> :error
    end
  end

  defp fallback_definition(store, file, line, assigns) do
    case ScipElixir.Store.find_ref_at(store, file, line) do
      %{target_module: mod, target_name: name, target_arity: arity} when not is_nil(mod) ->
        if is_nil(name) do
          find_module_definition(store, mod, assigns)
        else
          find_function_definition(store, mod, name, arity, assigns)
        end

      _ ->
        case ScipElixir.Store.find_symbol_at(store, file, line) do
          %{} = sym -> {:ok, symbol_to_location(sym, assigns)}
          nil -> :error
        end
    end
  end

  # --- References ---

  defp resolve_and_find_references(lsp, uri, file, line, col) do
    store = lsp.assigns.store
    source = get_source(lsp, uri, file)

    {module, name, arity} =
      case resolve_symbol_at_cursor(source, line, col) do
        {:module, mod_name} ->
          {mod_name, nil, nil}

        {:function_name, fn_name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^fn_name, target_arity: arity} ->
              {mod, fn_name, arity}

            _ ->
              {nil, fn_name, nil}
          end

        {:identifier, name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^name, target_arity: arity} ->
              {mod, name, arity}

            _ ->
              # Check if it's a symbol definition
              case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
                %{module: mod, name: ^name, arity: a} -> {mod, name, a}
                %{name: ^name, kind: "module"} -> {name, nil, nil}
                _ -> {nil, nil, nil}
              end
          end

        _ ->
          # Fallback
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: name, target_arity: arity} ->
              {mod, name, arity}

            nil ->
              case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
                %{module: _mod, name: n, arity: a, kind: "module"} -> {n, nil, a}
                %{module: mod, name: n, arity: a} -> {mod, n, a}
                _ -> {nil, nil, nil}
              end
          end
      end

    if module do
      ScipElixir.Store.find_refs(store, module, name, arity)
      |> Enum.map(fn ref -> ref_to_location(ref, lsp.assigns) end)
    else
      []
    end
  end

  # --- Hover ---

  defp resolve_and_hover(lsp, uri, file, line, col) do
    store = lsp.assigns.store
    source = get_source(lsp, uri, file)

    sym =
      case resolve_symbol_at_cursor(source, line, col) do
        {:module, mod_name} ->
          ScipElixir.Store.find_symbol(store, nil, mod_name, nil)

        {:function_name, fn_name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^fn_name, target_arity: arity} ->
              ScipElixir.Store.find_symbol(store, mod, fn_name, arity)

            _ ->
              nil
          end

        {:identifier, name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^name, target_arity: arity} ->
              ScipElixir.Store.find_symbol(store, mod, name, arity)

            _ ->
              ScipElixir.Store.find_symbol_at(store, file, line + 1)
          end

        _ ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: nil} ->
              ScipElixir.Store.find_symbol(store, nil, mod, nil)

            %{target_module: mod, target_name: name, target_arity: arity} ->
              ScipElixir.Store.find_symbol(store, mod, name, arity)

            nil ->
              ScipElixir.Store.find_symbol_at(store, file, line + 1)
          end
      end

    case sym do
      %{} = s -> {:ok, build_hover(s)}
      nil -> :error
    end
  end

  defp build_hover(sym) do
    signature = build_signature(sym)
    doc = sym[:documentation] || ""

    content =
      if doc != "" do
        "```elixir\n#{signature}\n```\n\n#{doc}"
      else
        "```elixir\n#{signature}\n```"
      end

    %Hover{
      contents: %MarkupContent{
        kind: GenLSP.Enumerations.MarkupKind.markdown(),
        value: content
      }
    }
  end

  defp build_signature(%{kind: "module", name: name}), do: "defmodule #{name}"

  defp build_signature(%{kind: "macro", module: mod, name: name, arity: arity}) do
    args = make_args(arity)
    "defmacro #{mod}.#{name}(#{args})"
  end

  defp build_signature(%{module: mod, name: name, arity: arity}) do
    args = make_args(arity)

    if mod do
      "def #{mod}.#{name}(#{args})"
    else
      "def #{name}(#{args})"
    end
  end

  defp make_args(nil), do: ""
  defp make_args(0), do: ""

  defp make_args(arity) when is_integer(arity) do
    1..arity
    |> Enum.map(fn i -> "arg#{i}" end)
    |> Enum.join(", ")
  end

  defp make_args(_), do: ""

  # --- Private: Conversions ---

  defp symbol_to_location(sym, _assigns) do
    line = max((sym[:line] || 1) - 1, 0)
    col = max((sym[:col] || 1) - 1, 0)

    %Location{
      uri: path_to_uri(sym[:file]),
      range: %Range{
        start: %Position{line: line, character: col},
        end: %Position{line: line, character: col}
      }
    }
  end

  defp ref_to_location(ref, _assigns) do
    line = max((ref[:line] || 1) - 1, 0)
    col = max((ref[:col] || 1) - 1, 0)

    %Location{
      uri: path_to_uri(ref[:file]),
      range: %Range{
        start: %Position{line: line, character: col},
        end: %Position{line: line, character: col}
      }
    }
  end

  defp symbol_to_document_symbol(sym) do
    line = max((sym[:line] || 1) - 1, 0)
    col = max((sym[:col] || 1) - 1, 0)
    end_line = max((sym[:end_line] || sym[:line] || 1) - 1, 0)
    end_col = max((sym[:end_col] || sym[:col] || 1) - 1, 0)

    name =
      case sym[:arity] do
        nil -> sym[:name]
        a -> "#{sym[:name]}/#{a}"
      end

    %DocumentSymbol{
      name: name,
      kind: kind_to_symbol_kind(sym[:kind]),
      range: %Range{
        start: %Position{line: line, character: col},
        end: %Position{line: end_line, character: end_col}
      },
      selection_range: %Range{
        start: %Position{line: line, character: col},
        end: %Position{line: line, character: col}
      }
    }
  end

  defp symbol_to_symbol_info(sym, _assigns) do
    line = max((sym[:line] || 1) - 1, 0)
    col = max((sym[:col] || 1) - 1, 0)

    name =
      case sym[:arity] do
        nil -> sym[:name]
        a -> "#{sym[:name]}/#{a}"
      end

    %SymbolInformation{
      name: name,
      kind: kind_to_symbol_kind(sym[:kind]),
      location: %Location{
        uri: path_to_uri(sym[:file]),
        range: %Range{
          start: %Position{line: line, character: col},
          end: %Position{line: line, character: col}
        }
      },
      container_name: sym[:module]
    }
  end

  defp kind_to_symbol_kind("module"), do: SymbolKind.module()
  defp kind_to_symbol_kind("function"), do: SymbolKind.function()
  defp kind_to_symbol_kind("macro"), do: SymbolKind.function()
  defp kind_to_symbol_kind("type"), do: SymbolKind.class()
  defp kind_to_symbol_kind("protocol"), do: SymbolKind.interface()
  defp kind_to_symbol_kind(_), do: SymbolKind.function()

  # --- Private: URI / Path helpers ---

  defp uri_to_path("file://" <> path), do: URI.decode(path)
  defp uri_to_path(path), do: path

  defp path_to_uri(path) when is_binary(path) do
    "file://" <> path
  end

  defp path_to_uri(_), do: "file:///unknown"

  defp resolve_db_path(db_path, root_uri) when is_binary(root_uri) do
    root = uri_to_path(root_uri)

    if Path.type(db_path) == :absolute do
      db_path
    else
      Path.join(root, db_path)
    end
  end

  defp resolve_db_path(db_path, _), do: db_path

  defp fts5_query(query) do
    # Sanitize for FTS5: wrap each word with * for prefix matching
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn word ->
      sanitized = String.replace(word, ~r/[^\w]/, "")
      if sanitized != "", do: "#{sanitized}*", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
