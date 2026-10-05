import * as vscode from "vscode";
import * as net from "net";
import * as path from "path";
import * as fs from "fs";

const SCHEME = "sprout";

// TODO(robin): this should be /var/run or something, according to POSIX, right?
const SOCKET_PATH = "/tmp/sprout.sock";

interface Request {
  path: string;
  old_content: string;
  new_content: string;
}

type Decision =
  { outcome: "accepted" }
  | { outcome: "edited"; content: string }
  | { outcome: "rejected" };

class Ghost implements vscode.TextDocumentContentProvider {
  // Read-only "before" side of the diff. (And "after" is the real file.)

  private content = new Map<string, string>();

  provideTextDocumentContent(uri: vscode.Uri): string {
    return this.content.get(uri.toString()) ?? "";
  }

  set(uri: vscode.Uri, content: string) {
    this.content.set(uri.toString(), content);
  }
}

const ghost = new Ghost();
let counter = 0;

export function activate(context: vscode.ExtensionContext) {
  const server = start_server();

  context.subscriptions.push({ dispose: () => server.close() });
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider(SCHEME, ghost));
}

export function deactivate() {}

// Server

function start_server(): net.Server {
  if (fs.existsSync(SOCKET_PATH)) fs.unlinkSync(SOCKET_PATH);

  const server = net.createServer(handler);

  server.on("error", (error) => console.error("socket server error", error));
  server.listen(SOCKET_PATH, () => console.log(`listening on ${SOCKET_PATH}`));

  return server;
}

function handler(client: net.Socket) {
  let buffer = "";

  client.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();

    const end = buffer.indexOf("\n");
    if (end == -1) return;

    const request = decode_request(buffer.slice(0, end));
    if (request) resolve_edit(client, request);
  });

  client.on("error", (error) => console.error("client socket error", error));
}

async function resolve_edit(client: net.Socket, request: Request) {
  try {
    const document = await present_edit(request);
    const decision = await wait_for_decision(document, request);

    respond(client, encode_decision(decision));
  } catch (err) {
    console.error("failed to resolve edit", err);

    respond(client, encode_decision({ outcome: "rejected" }));
  }
}

async function present_edit(request: Request): Promise<vscode.TextDocument> {
  const uri = vscode.Uri.file(request.path);

  const document = await vscode.workspace.openTextDocument(uri).then(
    (doc) => doc,
    () => vscode.workspace.openTextDocument({ content: request.old_content }),
  );

  await replace_content(document, request.new_content);

  counter++;

  const ghost_uri = vscode.Uri.parse(`${SCHEME}:/${counter}::${path.basename(request.path)}`);
  ghost.set(ghost_uri, request.old_content);

  await vscode.commands.executeCommand(
    "vscode.diff",
    ghost_uri,
    document.uri,
    `${path.basename(request.path)} (proposed edit)`,
    { preview: false, preserveFocus: true },
  );

  return document;
}

function wait_for_decision(document: vscode.TextDocument, request: Request): Promise<Decision> {
  // cmd+s on the diff tab approves, cmd+w rejects.

  return new Promise((resolve) => {
    let settled = false;

    const settle = (decision: Decision) => {
      if (settled) return;
      settled = true;
      save_listener.dispose();
      tab_listener.dispose();
      resolve(decision);
    };

    const save_listener = vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.uri.toString() != document.uri.toString()) return;

      const content = doc.getText();

      settle(content == request.new_content ?
        { outcome: "accepted" } :
        { outcome: "edited", content });

      close_diff_tab(document.uri);
    });

    const tab_listener = vscode.window.tabGroups.onDidChangeTabs((event) => {
      const ours = event.closed.some(
        (tab) => tab.input instanceof vscode.TabInputTextDiff
          && tab.input.modified.toString() == document.uri.toString(),
      );

      if (ours) settle({ outcome: "rejected" });
    });
  });
}

async function close_diff_tab(modified_uri: vscode.Uri) {
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      if (tab.input instanceof vscode.TabInputTextDiff
          && tab.input.modified.toString() == modified_uri.toString()) {
        await vscode.window.tabGroups.close(tab);
        return;
      }
    }
  }
}

async function replace_content(document: vscode.TextDocument, content: string) {
  const edit = new vscode.WorkspaceEdit();
  edit.replace(document.uri, full_range(document), content);
  await vscode.workspace.applyEdit(edit);
}

function full_range(document: vscode.TextDocument): vscode.Range {
  const last_line = document.lineAt(document.lineCount - 1);
  return new vscode.Range(new vscode.Position(0, 0), last_line.range.end);
}

function respond(client: net.Socket, message: string) {
  if (!client.destroyed) client.write(message);
}

// Protocol

function decode_request(line: string): Request | null {
  const parts = line.split("|");

  if (parts.length != 4 || parts[0] != "EDIT") return null;

  const [_, request_path, old_content, new_content] = parts;

  return {
    path: decode(request_path),
    old_content: decode(old_content),
    new_content: decode(new_content)
  };
}

function encode_decision(decision: Decision): string {
  switch (decision.outcome) {
    case "accepted": return "ACCEPTED\n";
    case "edited": return `EDITED|${encode(decision.content)}\n`;
    case "rejected": return "REJECTED\n";
  }
}

function encode(value: string): string {
  return value.replace(/\|/g, "\\|").replace(/\n/g, "\\n");
}

function decode(value: string): string {
  return value.replace(/\\n/g, "\n").replace(/\\\|/g, "|");
}
