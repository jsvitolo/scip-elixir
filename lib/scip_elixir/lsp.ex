defmodule ScipElixir.LSP do
  @moduledoc """
  LSP server for scip-elixir using gen_lsp.

  Provides code intelligence by querying the SQLite index built
  by the compiler tracer.

  ## Capabilities

  - `textDocument/definition` — go to definition
  - `textDocument/references` — find all references
  - `textDocument/hover` — documentation on hover
  - `textDocument/rename` — rename symbol across project
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
    DocumentSymbol,
    WorkspaceEdit,
    TextEdit
  }

  alias GenLSP.Requests.{
    Initialize,
    TextDocumentDefinition,
    TextDocumentReferences,
    TextDocumentHover,
    TextDocumentRename,
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

    # Start companion processes if not provided
    lsp_opts =
      lsp_opts
      |> ensure_started(:buffer, fn ->
        GenLSP.Buffer.start_link(communication: {GenLSP.Communication.Stdio, []})
      end)
      |> ensure_started(:assigns, fn -> GenLSP.Assigns.start_link([]) end)
      |> ensure_started(:task_supervisor, fn -> Task.Supervisor.start_link([]) end)

    GenLSP.start_link(__MODULE__, opts, lsp_opts)
  end

  defp ensure_started(opts, key, starter) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      {:ok, pid} = starter.()
      Keyword.put(opts, key, pid)
    end
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
    db_path = resolve_db_path(assigns(lsp).db_path, root_uri)

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
         rename_provider: true,
         document_symbol_provider: true,
         workspace_symbol_provider: true
       },
       server_info: %{name: "scip-elixir", version: "0.1.1"}
     }, assign(lsp, store: store, root_uri: root_uri)}
  end

  # --- textDocument/definition ---

  def handle_request(%TextDocumentDefinition{params: params}, lsp) do
    if assigns(lsp).store == nil do
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
    if assigns(lsp).store == nil do
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

  # --- textDocument/rename ---

  def handle_request(%TextDocumentRename{params: params}, lsp) do
    if assigns(lsp).store == nil do
      {:reply, nil, lsp}
    else
      uri = params.text_document.uri
      line = params.position.line
      col = params.position.character
      file = uri_to_path(uri)
      new_name = params.new_name

      case resolve_and_rename(lsp, uri, file, line, col, new_name) do
        {:ok, workspace_edit} -> {:reply, workspace_edit, lsp}
        :error -> {:reply, nil, lsp}
      end
    end
  end

  # --- textDocument/hover ---

  def handle_request(%TextDocumentHover{params: params}, lsp) do
    if assigns(lsp).store == nil do
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
    if assigns(lsp).store == nil do
      {:reply, [], lsp}
    else
      uri = params.text_document.uri
      file = uri_to_path(uri)

      symbols =
        ScipElixir.Store.symbols_in_file(assigns(lsp).store, file)
        |> Enum.map(&symbol_to_document_symbol/1)

      {:reply, symbols, lsp}
    end
  end

  # --- workspace/symbol ---

  def handle_request(%WorkspaceSymbol{params: params}, lsp) do
    if assigns(lsp).store == nil do
      {:reply, [], lsp}
    else
      query = params.query

      if String.length(query) < 2 do
        {:reply, [], lsp}
      else
        symbols =
          ScipElixir.Store.search(assigns(lsp).store, fts5_query(query))
          |> Enum.map(fn sym -> symbol_to_symbol_info(sym, assigns(lsp)) end)

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
    if assigns(lsp).store do
      stats = ScipElixir.Store.stats(assigns(lsp).store)

      GenLSP.log(lsp, "[scip-elixir] Index loaded: #{stats.symbols} symbols, #{stats.refs} refs across #{stats.files} files")
    else
      GenLSP.warning(lsp, "[scip-elixir] No index found. Run: mix scip.index")
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    uri = params.text_document.uri
    text = params.text_document.text
    documents = Map.put(assigns(lsp).documents, uri, text)
    {:noreply, assign(lsp, documents: documents)}
  end

  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    uri = params.text_document.uri

    # Full sync mode — last content change has the full text
    text =
      case params.content_changes do
        [%{text: text} | _] -> text
        _ -> Map.get(assigns(lsp).documents, uri, "")
      end

    documents = Map.put(assigns(lsp).documents, uri, text)
    {:noreply, assign(lsp, documents: documents)}
  end

  def handle_notification(%TextDocumentDidSave{}, lsp) do
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    uri = params.text_document.uri
    documents = Map.delete(assigns(lsp).documents, uri)
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
    case Map.get(assigns(lsp).documents, uri) do
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
    store = assigns(lsp).store
    source = get_source(lsp, uri, file)

    # First try tree-sitter resolution
    case resolve_symbol_at_cursor(source, line, col) do
      {:module, mod_name} ->
        find_module_definition(store, mod_name, assigns(lsp))

      {:function_name, fn_name} ->
        # Try to find via ref at this line (has module context)
        case ScipElixir.Store.find_ref_at(store, file, line + 1) do
          %{target_module: mod, target_name: ^fn_name, target_arity: arity} ->
            find_function_definition(store, mod, fn_name, arity, assigns(lsp))

          _ ->
            # No matching ref — might be hovering over a definition
            case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
              %{} = sym -> {:ok, symbol_to_location(sym, assigns(lsp))}
              nil -> search_definition_by_name(store, fn_name, assigns(lsp))
            end
        end

      {:identifier, name} ->
        # Could be a local function call or variable
        case ScipElixir.Store.find_ref_at(store, file, line + 1) do
          %{target_module: mod, target_name: ^name, target_arity: arity} ->
            find_function_definition(store, mod, name, arity, assigns(lsp))

          _ ->
            case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
              %{} = sym -> {:ok, symbol_to_location(sym, assigns(lsp))}
              nil -> search_definition_by_name(store, name, assigns(lsp))
            end
        end

      _ ->
        # Fallback to line-based lookup
        fallback_definition(store, file, line + 1, assigns(lsp))
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
    result =
      case ScipElixir.Store.find_ref_at(store, file, line) do
        %{target_module: mod, target_name: name, target_arity: arity} when not is_nil(mod) ->
          if is_nil(name) do
            find_module_definition(store, mod, assigns)
          else
            find_function_definition(store, mod, name, arity, assigns)
          end

        _ ->
          :error
      end

    # If ref-based lookup failed, try symbol at position
    case result do
      {:ok, _} = ok -> ok
      :error ->
        case ScipElixir.Store.find_symbol_at(store, file, line) do
          %{} = sym -> {:ok, symbol_to_location(sym, assigns)}
          nil -> :error
        end
    end
  end

  # --- References ---

  defp resolve_and_find_references(lsp, uri, file, line, col) do
    store = assigns(lsp).store
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
              # On a definition — look up symbol directly to get module info
              case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
                %{module: mod, name: ^fn_name, arity: a} -> {mod, fn_name, a}
                %{name: ^fn_name, kind: "module"} -> {fn_name, nil, nil}
                _ -> {nil, fn_name, nil}
              end
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
      |> Enum.map(fn ref -> ref_to_location(ref, assigns(lsp)) end)
    else
      []
    end
  end

  # --- Rename ---

  defp resolve_and_rename(lsp, uri, file, line, col, new_name) do
    store = assigns(lsp).store
    source = get_source(lsp, uri, file)

    # Resolve what's at cursor — reuse the same logic as references
    {module, old_name, arity} =
      case resolve_symbol_at_cursor(source, line, col) do
        {:function_name, fn_name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^fn_name, target_arity: a} ->
              {mod, fn_name, a}

            _ ->
              case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
                %{module: mod, name: ^fn_name, arity: a} -> {mod, fn_name, a}
                _ -> {nil, nil, nil}
              end
          end

        {:identifier, name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^name, target_arity: a} ->
              {mod, name, a}

            _ ->
              case ScipElixir.Store.find_symbol_at(store, file, line + 1) do
                %{module: mod, name: ^name, arity: a} -> {mod, name, a}
                _ -> {nil, nil, nil}
              end
          end

        _ ->
          {nil, nil, nil}
      end

    if is_nil(old_name) do
      :error
    else
      # Collect all locations to rename
      edits = collect_rename_locations(store, module, old_name, arity, file)

      if edits == [] do
        :error
      else
        changes = build_rename_changes(edits, old_name, new_name)
        {:ok, %WorkspaceEdit{changes: changes}}
      end
    end
  end

  # Collect all locations where the name appears: definition + all references
  defp collect_rename_locations(store, module, name, arity, _file) do
    # 1. Find the definition symbol
    def_locations =
      case ScipElixir.Store.find_symbol(store, module, name, arity) do
        %{file: f, line: l} = sym ->
          # Symbol col points to `def`/`defp`, need to find the name column
          case find_name_col_in_def(f, l, name) do
            {:ok, name_col} -> [{f, l, name_col}]
            :error -> [{f, l, sym[:col]}]
          end

        nil ->
          []
      end

    # 2. Find all references (call sites)
    ref_locations =
      ScipElixir.Store.find_refs(store, module, name, arity)
      |> Enum.filter(fn ref -> ref[:kind] == "function" end)
      |> Enum.map(fn ref -> {ref[:file], ref[:line], ref[:col]} end)

    # Deduplicate (some refs appear twice due to compiler tracing)
    (def_locations ++ ref_locations)
    |> Enum.uniq()
  end

  # Find the exact column of the function name within a definition line.
  # For `  def open(path) do`, col of symbol is 3 (pointing to `def`),
  # but we need col 7 (pointing to `open`).
  defp find_name_col_in_def(file, line, name) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        if line >= 1 and line <= length(lines) do
          source_line = Enum.at(lines, line - 1)
          # Match def/defp/defmacro/defmacrop followed by the name
          pattern = ~r/(def|defp|defmacro|defmacrop|defguard|defguardp)\s+#{Regex.escape(name)}/
          case Regex.run(pattern, source_line, return: :index) do
            [{start, len} | _] ->
              # The name starts after the keyword + space
              name_start = start + len - String.length(name)
              # Convert to 1-indexed
              {:ok, name_start + 1}

            _ ->
              :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  # Build WorkspaceEdit changes map: %{uri => [TextEdit]}
  defp build_rename_changes(locations, old_name, new_name) do
    name_len = String.length(old_name)

    locations
    |> Enum.group_by(fn {file, _line, _col} -> path_to_uri(file) end)
    |> Enum.map(fn {uri, locs} ->
      text_edits =
        Enum.map(locs, fn {_file, line, col} ->
          # DB uses 1-indexed, LSP uses 0-indexed
          lsp_line = line - 1
          lsp_col = col - 1

          %TextEdit{
            range: %Range{
              start: %Position{line: lsp_line, character: lsp_col},
              end: %Position{line: lsp_line, character: lsp_col + name_len}
            },
            new_text: new_name
          }
        end)

      {uri, text_edits}
    end)
    |> Map.new()
  end

  # --- Hover ---

  defp resolve_and_hover(lsp, uri, file, line, col) do
    store = assigns(lsp).store
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
              # Hovering over a definition — no useful ref, look up symbol directly
              ScipElixir.Store.find_symbol_at(store, file, line + 1)
          end

        {:identifier, name} ->
          case ScipElixir.Store.find_ref_at(store, file, line + 1) do
            %{target_module: mod, target_name: ^name, target_arity: arity} ->
              ScipElixir.Store.find_symbol(store, mod, name, arity)

            _ ->
              ScipElixir.Store.find_symbol_at(store, file, line + 1)
          end

        _ ->
          resolve_hover_from_ref_or_symbol(store, file, line + 1)
      end

    case sym do
      %{} = s -> {:ok, build_hover(s)}
      nil -> :error
    end
  end

  # Try ref-based lookup first, then fall back to symbol-at-position
  defp resolve_hover_from_ref_or_symbol(store, file, line) do
    result =
      case ScipElixir.Store.find_ref_at(store, file, line) do
        %{target_module: mod, target_name: nil} ->
          ScipElixir.Store.find_symbol(store, nil, mod, nil)

        %{target_module: mod, target_name: name, target_arity: arity} ->
          ScipElixir.Store.find_symbol(store, mod, name, arity)

        nil ->
          nil
      end

    # If ref-based lookup failed, try symbol at position
    result || ScipElixir.Store.find_symbol_at(store, file, line)
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
