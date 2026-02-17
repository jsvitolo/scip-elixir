defmodule ScipElixir.Store do
  @moduledoc """
  SQLite storage for the SCIP index.

  Stores symbols (definitions) and refs (references) in SQLite with
  FTS5 full-text search for workspace symbol search.
  """

  @doc "Open a SQLite database and initialize the schema."
  def open(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = migrate(conn)
    {:ok, conn}
  end

  @doc "Close the database connection."
  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  @doc "Save symbols and refs to the database."
  def save(conn, symbols, refs) do
    :ok = execute(conn, "BEGIN TRANSACTION")

    for sym <- symbols do
      save_symbol(conn, sym)
    end

    for ref <- refs do
      save_ref(conn, ref)
    end

    :ok = execute(conn, "COMMIT")
    {:ok, %{symbols: length(symbols), refs: length(refs)}}
  end

  @doc "Clear all data for a specific file (for incremental re-index)."
  def clear_file(conn, file) do
    :ok = execute(conn, "BEGIN TRANSACTION")
    :ok = execute(conn, "DELETE FROM symbols WHERE file = ?1", [file])
    :ok = execute(conn, "DELETE FROM refs WHERE file = ?1", [file])
    :ok = execute(conn, "COMMIT")
    :ok
  end

  @doc "Clear all data in the database."
  def clear_all(conn) do
    :ok = execute(conn, "BEGIN TRANSACTION")
    :ok = execute(conn, "DELETE FROM symbols")
    :ok = execute(conn, "DELETE FROM refs")
    :ok = execute(conn, "DELETE FROM relationships")
    :ok = execute(conn, "COMMIT")
    :ok
  end

  # --- Query API ---

  @doc "Find symbol definitions by file."
  def symbols_in_file(conn, file) do
    query(conn, "SELECT * FROM symbols WHERE file = ?1 ORDER BY line, col", [file])
  end

  @doc "Find a symbol definition by module and name."
  def find_symbol(conn, module, name, arity) do
    query(conn, """
      SELECT * FROM symbols
      WHERE module = ?1 AND name = ?2 AND (arity = ?3 OR ?3 IS NULL)
      LIMIT 1
    """, [module, name, arity])
  end

  @doc "Find all references to a symbol."
  def find_refs(conn, module, name, arity) do
    query(conn, """
      SELECT * FROM refs
      WHERE target_module = ?1 AND target_name = ?2 AND (target_arity = ?3 OR ?3 IS NULL)
      ORDER BY file, line
    """, [module, name, arity])
  end

  @doc "Full-text search over symbol names and modules."
  def search(conn, query_text, limit \\ 20) do
    query(conn, """
      SELECT s.*, symbols_fts.rank
      FROM symbols_fts
      JOIN symbols s ON s.rowid = symbols_fts.rowid
      WHERE symbols_fts MATCH ?1
      ORDER BY symbols_fts.rank
      LIMIT ?2
    """, [query_text, limit])
  end

  @doc "Get index statistics."
  def stats(conn) do
    [{sym_count}] = query(conn, "SELECT COUNT(*) FROM symbols", [])
    [{ref_count}] = query(conn, "SELECT COUNT(*) FROM refs", [])
    [{file_count}] = query(conn, "SELECT COUNT(DISTINCT file) FROM symbols", [])

    %{
      symbols: sym_count,
      refs: ref_count,
      files: file_count
    }
  end

  # --- Private ---

  defp migrate(conn) do
    execute(conn, "PRAGMA journal_mode=WAL")
    execute(conn, "PRAGMA synchronous=NORMAL")

    execute(conn, """
      CREATE TABLE IF NOT EXISTS symbols (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT,
        module TEXT,
        file TEXT NOT NULL,
        line INTEGER,
        col INTEGER,
        end_line INTEGER,
        end_col INTEGER,
        arity INTEGER,
        documentation TEXT
      )
    """)

    execute(conn, """
      CREATE TABLE IF NOT EXISTS refs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file TEXT NOT NULL,
        line INTEGER,
        col INTEGER,
        target_module TEXT,
        target_name TEXT,
        target_arity INTEGER,
        kind TEXT
      )
    """)

    execute(conn, """
      CREATE TABLE IF NOT EXISTS relationships (
        from_symbol TEXT,
        to_symbol TEXT,
        kind TEXT
      )
    """)

    # FTS5 for workspace search
    execute(conn, """
      CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
        name, module, documentation,
        content='symbols',
        content_rowid='rowid',
        tokenize='porter unicode61'
      )
    """)

    # Indexes
    execute(conn, "CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file)")
    execute(conn, "CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbols(module)")
    execute(conn, "CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name)")
    execute(conn, "CREATE INDEX IF NOT EXISTS idx_refs_file ON refs(file)")
    execute(conn, "CREATE INDEX IF NOT EXISTS idx_refs_target ON refs(target_module, target_name)")

    # FTS triggers for automatic sync
    execute(conn, """
      CREATE TRIGGER IF NOT EXISTS symbols_ai AFTER INSERT ON symbols BEGIN
        INSERT INTO symbols_fts(rowid, name, module, documentation)
        VALUES (new.rowid, new.name, new.module, new.documentation);
      END
    """)

    execute(conn, """
      CREATE TRIGGER IF NOT EXISTS symbols_ad AFTER DELETE ON symbols BEGIN
        INSERT INTO symbols_fts(symbols_fts, rowid, name, module, documentation)
        VALUES ('delete', old.rowid, old.name, old.module, old.documentation);
      END
    """)

    :ok
  end

  defp save_symbol(conn, sym) do
    id = symbol_id(sym)

    execute(conn, """
      INSERT OR REPLACE INTO symbols (id, name, kind, module, file, line, col, arity, documentation)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    """, [
      id,
      sym.name,
      to_string(sym.kind),
      sym.module,
      sym.file,
      sym.line,
      sym.column,
      sym.arity,
      sym.documentation
    ])
  end

  defp save_ref(conn, ref) do
    execute(conn, """
      INSERT INTO refs (file, line, col, target_module, target_name, target_arity, kind)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """, [
      ref.file,
      ref.line,
      ref.column,
      ref.target_module,
      ref.target_name,
      ref.target_arity,
      to_string(ref.kind)
    ])
  end

  defp symbol_id(%{module: nil, name: name, arity: nil}), do: name
  defp symbol_id(%{module: nil, name: name, arity: arity}), do: "#{name}/#{arity}"
  defp symbol_id(%{module: _mod, name: name, kind: :module}), do: name
  defp symbol_id(%{module: mod, name: name, arity: nil}), do: "#{mod}.#{name}"
  defp symbol_id(%{module: mod, name: name, arity: arity}), do: "#{mod}.#{name}/#{arity}"

  defp execute(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    if params != [] do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
    end

    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _row} -> drain_rows(conn, stmt)
      {:error, reason} -> {:error, reason}
    end
  after
    # stmt is released automatically by GC, but let's be explicit
    :ok
  end

  defp query(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    if params != [] do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
    end

    collect_rows(conn, stmt, [])
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [List.to_tuple(row) | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp drain_rows(conn, stmt) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, _} -> drain_rows(conn, stmt)
      :done -> :ok
    end
  end
end
