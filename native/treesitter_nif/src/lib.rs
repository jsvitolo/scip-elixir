use rustler::NifResult;
use tree_sitter::{Node, Parser, Point};

/// A definition found in the source code.
#[derive(rustler::NifStruct)]
#[module = "ScipElixir.TreeSitter.Definition"]
pub struct Definition {
    pub kind: String,
    pub name: String,
    pub arity: i32,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

/// Info about a node at a given position.
#[derive(rustler::NifStruct)]
#[module = "ScipElixir.TreeSitter.NodeInfo"]
pub struct NodeInfo {
    pub kind: String,
    pub text: String,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
    pub parent_kind: String,
}

/// Parse Elixir source and return the S-expression tree.
#[rustler::nif]
fn parse(source_code: &str) -> NifResult<String> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_elixir::LANGUAGE.into())
        .map_err(|e| rustler::Error::Term(Box::new(format!("{e}"))))?;

    let tree = parser
        .parse(source_code, None)
        .ok_or_else(|| rustler::Error::Term(Box::new("Parse failed".to_string())))?;

    Ok(tree.root_node().to_sexp())
}

/// Extract all definitions (modules, functions, macros) from Elixir source.
#[rustler::nif(schedule = "DirtyCpu")]
fn find_definitions(source_code: &str) -> NifResult<Vec<Definition>> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_elixir::LANGUAGE.into())
        .map_err(|e| rustler::Error::Term(Box::new(format!("{e}"))))?;

    let tree = parser
        .parse(source_code, None)
        .ok_or_else(|| rustler::Error::Term(Box::new("Parse failed".to_string())))?;

    let mut defs = Vec::new();
    collect_definitions(&tree.root_node(), source_code.as_bytes(), &mut defs);
    Ok(defs)
}

/// Find a named child of a given kind.
fn find_child_by_kind<'a>(node: &'a Node<'a>, kind: &str) -> Option<Node<'a>> {
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if child.kind() == kind {
            return Some(child);
        }
    }
    None
}

fn collect_definitions(node: &Node, source: &[u8], defs: &mut Vec<Definition>) {
    if node.kind() == "call" {
        if let Some(target) = node.child_by_field_name("target") {
            if target.kind() == "identifier" {
                let target_text = node_text(&target, source);

                match target_text.as_str() {
                    "defmodule" | "defprotocol" => {
                        if let Some(name) = extract_module_name(node, source) {
                            defs.push(Definition {
                                kind: "module".to_string(),
                                name,
                                arity: -1,
                                line: node.start_position().row as u32,
                                col: node.start_position().column as u32,
                                end_line: node.end_position().row as u32,
                                end_col: node.end_position().column as u32,
                            });
                        }
                    }
                    "def" | "defp" | "defdelegate" | "defguard" | "defguardp" => {
                        if let Some((name, arity)) = extract_fn_signature(node, source) {
                            defs.push(Definition {
                                kind: "function".to_string(),
                                name,
                                arity,
                                line: node.start_position().row as u32,
                                col: node.start_position().column as u32,
                                end_line: node.end_position().row as u32,
                                end_col: node.end_position().column as u32,
                            });
                        }
                    }
                    "defmacro" | "defmacrop" => {
                        if let Some((name, arity)) = extract_fn_signature(node, source) {
                            defs.push(Definition {
                                kind: "macro".to_string(),
                                name,
                                arity,
                                line: node.start_position().row as u32,
                                col: node.start_position().column as u32,
                                end_line: node.end_position().row as u32,
                                end_col: node.end_position().column as u32,
                            });
                        }
                    }
                    "defstruct" => {
                        defs.push(Definition {
                            kind: "struct".to_string(),
                            name: "__struct__".to_string(),
                            arity: 0,
                            line: node.start_position().row as u32,
                            col: node.start_position().column as u32,
                            end_line: node.end_position().row as u32,
                            end_col: node.end_position().column as u32,
                        });
                    }
                    _ => {}
                }
            }
        }
    }

    // Recurse into children
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_definitions(&child, source, defs);
    }
}

fn extract_module_name(call_node: &Node, source: &[u8]) -> Option<String> {
    // In tree-sitter-elixir: (call target: (identifier) (arguments (alias)))
    let args = find_child_by_kind(call_node, "arguments")?;
    let first = args.named_child(0)?;

    match first.kind() {
        "alias" | "dot" => Some(node_text(&first, source)),
        _ => None,
    }
}

fn extract_fn_signature(call_node: &Node, source: &[u8]) -> Option<(String, i32)> {
    // In tree-sitter-elixir: (call target: (identifier) (arguments ...))
    let args = find_child_by_kind(call_node, "arguments")?;
    let first = args.named_child(0)?;

    match first.kind() {
        // Zero-arity without parens: def my_fun do ... end
        // Also handles: def my_fun, do: :ok
        "identifier" => Some((node_text(&first, source), 0)),

        // Regular: def my_fun(a, b) do ... end
        "call" => {
            let name_node = first.child_by_field_name("target")?;
            let name = node_text(&name_node, source);
            let arity = find_child_by_kind(&first, "arguments")
                .map(|a| a.named_child_count() as i32)
                .unwrap_or(0);
            Some((name, arity))
        }

        // With guard: def my_fun(a) when is_integer(a) do ... end
        "binary_operator" => {
            let left = first.child_by_field_name("left")?;
            match left.kind() {
                "identifier" => Some((node_text(&left, source), 0)),
                "call" => {
                    let name_node = left.child_by_field_name("target")?;
                    let name = node_text(&name_node, source);
                    let arity = find_child_by_kind(&left, "arguments")
                        .map(|a| a.named_child_count() as i32)
                        .unwrap_or(0);
                    Some((name, arity))
                }
                _ => None,
            }
        }

        _ => None,
    }
}

/// Find the most specific named node at a given (line, col) position.
#[rustler::nif]
fn node_at_position(source_code: &str, line: u32, col: u32) -> NifResult<NodeInfo> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_elixir::LANGUAGE.into())
        .map_err(|e| rustler::Error::Term(Box::new(format!("{e}"))))?;

    let tree = parser
        .parse(source_code, None)
        .ok_or_else(|| rustler::Error::Term(Box::new("Parse failed".to_string())))?;

    let point = Point::new(line as usize, col as usize);
    let node = tree
        .root_node()
        .named_descendant_for_point_range(point, point)
        .ok_or_else(|| rustler::Error::Term(Box::new("No node at position".to_string())))?;

    let text = node_text(&node, source_code.as_bytes());
    let parent_kind = node
        .parent()
        .map(|p| p.kind().to_string())
        .unwrap_or_default();

    Ok(NodeInfo {
        kind: node.kind().to_string(),
        text,
        line: node.start_position().row as u32,
        col: node.start_position().column as u32,
        end_line: node.end_position().row as u32,
        end_col: node.end_position().column as u32,
        parent_kind,
    })
}

/// Parse HEEx template source and return the S-expression tree.
#[rustler::nif]
fn parse_heex(source_code: &str) -> NifResult<String> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_heex::LANGUAGE.into())
        .map_err(|e| rustler::Error::Term(Box::new(format!("{e}"))))?;

    let tree = parser
        .parse(source_code, None)
        .ok_or_else(|| rustler::Error::Term(Box::new("Parse failed".to_string())))?;

    Ok(tree.root_node().to_sexp())
}

// --- Helpers ---

fn node_text(node: &Node, source: &[u8]) -> String {
    std::str::from_utf8(&source[node.byte_range()])
        .unwrap_or("")
        .to_string()
}

rustler::init!("Elixir.ScipElixir.TreeSitter");
