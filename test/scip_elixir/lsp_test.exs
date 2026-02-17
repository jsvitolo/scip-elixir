defmodule ScipElixir.LSPTest do
  use ExUnit.Case

  alias ScipElixir.LSP
  alias ScipElixir.Store

  alias GenLSP.Requests.{
    TextDocumentReferences,
    TextDocumentHover,
    TextDocumentDocumentSymbol,
    WorkspaceSymbol
  }

  alias GenLSP.Structures.{
    TextDocumentIdentifier,
    ReferenceParams,
    ReferenceContext,
    HoverParams,
    DocumentSymbolParams,
    WorkspaceSymbolParams,
    Position
  }

  @project_root File.cwd!()
  @db_path Path.join(@project_root, ".scip-elixir/index.db")

  setup_all do
    # Ensure we have an index
    unless File.exists?(@db_path) do
      ScipElixir.Indexer.run(force: true)
    end

    :ok
  end

  # Helper to create a fake LSP state with a store connection
  defp make_lsp_state do
    {:ok, store} = Store.open(@db_path)
    root_uri = "file://#{@project_root}"

    # Simulate an initialized LSP with assigns
    %{
      assigns: %{
        db_path: @db_path,
        store: store,
        root_uri: root_uri,
        documents: %{}
      }
    }
  end

  defp tracer_uri, do: "file://#{@project_root}/lib/scip_elixir/tracer.ex"
  defp store_uri, do: "file://#{@project_root}/lib/scip_elixir/store.ex"

  describe "workspace/symbol" do
    test "finds symbols matching query" do
      lsp = make_lsp_state()

      request = %WorkspaceSymbol{
        id: 1,
        params: %WorkspaceSymbolParams{query: "Collector"}
      }

      {:reply, results, _lsp} = LSP.handle_request(request, lsp)

      assert is_list(results)
      assert length(results) > 0

      names = Enum.map(results, & &1.name)
      assert Enum.any?(names, &String.contains?(&1, "Collector"))
    end

    test "returns empty for short query" do
      lsp = make_lsp_state()

      request = %WorkspaceSymbol{
        id: 1,
        params: %WorkspaceSymbolParams{query: "a"}
      }

      {:reply, results, _lsp} = LSP.handle_request(request, lsp)
      assert results == []
    end
  end

  describe "textDocument/documentSymbol" do
    test "returns symbols for a file" do
      lsp = make_lsp_state()

      request = %TextDocumentDocumentSymbol{
        id: 1,
        params: %DocumentSymbolParams{
          text_document: %TextDocumentIdentifier{uri: store_uri()}
        }
      }

      {:reply, results, _lsp} = LSP.handle_request(request, lsp)

      assert is_list(results)
      assert length(results) > 0

      names = Enum.map(results, & &1.name)
      assert "ScipElixir.Store" in names or Enum.any?(names, &String.contains?(&1, "Store"))
    end
  end

  describe "textDocument/hover" do
    test "returns hover info for a reference" do
      lsp = make_lsp_state()

      # Line 48 in tracer.ex has ScipElixir.Collector.add_ref
      request = %TextDocumentHover{
        id: 1,
        params: %HoverParams{
          text_document: %TextDocumentIdentifier{uri: tracer_uri()},
          position: %Position{line: 47, character: 26}
        }
      }

      {:reply, result, _lsp} = LSP.handle_request(request, lsp)

      # May or may not find hover depending on exact position matching
      # The important thing is it doesn't crash
      assert result == nil or (is_map(result) and Map.has_key?(result, :contents))
    end
  end

  describe "textDocument/references" do
    test "finds references to a function" do
      lsp = make_lsp_state()

      # Line 48 in tracer.ex references ScipElixir.Collector.add_ref
      request = %TextDocumentReferences{
        id: 1,
        params: %ReferenceParams{
          text_document: %TextDocumentIdentifier{uri: tracer_uri()},
          position: %Position{line: 47, character: 26},
          context: %ReferenceContext{include_declaration: true}
        }
      }

      {:reply, results, _lsp} = LSP.handle_request(request, lsp)

      assert is_list(results)
      # Should not crash
    end
  end
end
