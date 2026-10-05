import * as vscode from "vscode";
import * as net from "net";
import * as path from "path";
import * as fs from "fs";

// TODO(robin): this should be /var/run or something, according to POSIX, right?
const SOCKET_PATH = "/tmp/sprout-vscode.sock";

interface EditRequest {
  path: string;
  oldContent: string;
  newContent: string;
}

const DIFF_SCHEME = "sprout-diff";

// Serves the read-only "before" side of the diff; the "after" side is the real file's own buffer.
class OldContentProvider implements vscode.TextDocumentContentProvider {
  private content = new Map<string, string>();

  provideTextDocumentContent(uri: vscode.Uri): string {
    return this.content.get(uri.toString()) ?? "";
  }

  set(uri: vscode.Uri, content: string) {
    this.content.set(uri.toString(), content);
  }
}

const oldContentProvider = new OldContentProvider();
let diffCounter = 0;

export function activate(context: vscode.ExtensionContext) {
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider(DIFF_SCHEME, oldContentProvider));

  const server = startServer();
  context.subscriptions.push({ dispose: () => server.close() });
}

export function deactivate() {}

// Server

function startServer(): net.Server {
  if (fs.existsSync(SOCKET_PATH)) {
    fs.unlinkSync(SOCKET_PATH);
  }

  const server = net
    .createServer(handleConnection)
    .on("error", (err) => console.error("sprout-vscode: socket server error", err));

  server.listen(SOCKET_PATH, () => console.log(`sprout-vscode: listening on ${SOCKET_PATH}`));

  return server;
}

function handleConnection(client: net.Socket) {
  let buffer = "";

  client.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();

    const end = buffer.indexOf("\n");
    if (end == -1) return;

    const request = decodeRequest(buffer.slice(0, end));
    if (request) resolveEdit(client, request);
  });

  client.on("error", (err) => console.error("sprout-vscode: client socket error", err));
}

// Edit workflow: cmd+s on the diff tab approves, cmd+w rejects.

type Decision = { outcome: "accepted" } | { outcome: "edited"; content: string } | { outcome: "rejected" };

async function resolveEdit(client: net.Socket, request: EditRequest) {
  try {
    const document = await presentEdit(request);
    const decision = await waitForDecision(document, request);

    if (decision.outcome == "accepted") {
      respond(client, "ACCEPTED\n");
    } else if (decision.outcome == "edited") {
      respond(client, `EDITED|${encode(decision.content)}\n`);
    } else {
      respond(client, "REJECTED\n");
    }
  } catch (err) {
    console.error("sprout-vscode: failed to resolve edit", err);
    respond(client, "REJECTED\n");
  }
}

async function presentEdit(request: EditRequest): Promise<vscode.TextDocument> {
  const uri = vscode.Uri.file(request.path);

  const document = await vscode.workspace.openTextDocument(uri).then(
    (doc) => doc,
    () => vscode.workspace.openTextDocument({ content: request.oldContent }),
  );

  await replaceContent(document, request.newContent);

  diffCounter++;
  const oldUri = vscode.Uri.parse(`${DIFF_SCHEME}:/${diffCounter}-${path.basename(request.path)}`);
  oldContentProvider.set(oldUri, request.oldContent);

  await vscode.commands.executeCommand(
    "vscode.diff",
    oldUri,
    document.uri,
    `${path.basename(request.path)} — proposed edit`,
    { preview: false, preserveFocus: true },
  );

  return document;
}

function waitForDecision(document: vscode.TextDocument, request: EditRequest): Promise<Decision> {
  return new Promise((resolve) => {
    let settled = false;

    const settle = (decision: Decision) => {
      if (settled) return;
      settled = true;
      saveListener.dispose();
      tabListener.dispose();
      resolve(decision);
    };

    const saveListener = vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.uri.toString() != document.uri.toString()) return;

      const content = doc.getText();
      settle(content == request.newContent ? { outcome: "accepted" } : { outcome: "edited", content });
      closeDiffTab(document.uri);
    });

    const tabListener = vscode.window.tabGroups.onDidChangeTabs((event) => {
      const closedOurs = event.closed.some(
        (tab) => tab.input instanceof vscode.TabInputTextDiff && tab.input.modified.toString() == document.uri.toString(),
      );
      if (closedOurs) settle({ outcome: "rejected" });
    });
  });
}

async function closeDiffTab(modifiedUri: vscode.Uri) {
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      if (tab.input instanceof vscode.TabInputTextDiff && tab.input.modified.toString() == modifiedUri.toString()) {
        await vscode.window.tabGroups.close(tab);
        return;
      }
    }
  }
}

async function replaceContent(document: vscode.TextDocument, content: string) {
  const edit = new vscode.WorkspaceEdit();
  edit.replace(document.uri, fullRange(document), content);
  await vscode.workspace.applyEdit(edit);
}

function fullRange(document: vscode.TextDocument): vscode.Range {
  const lastLine = document.lineAt(document.lineCount - 1);
  return new vscode.Range(new vscode.Position(0, 0), lastLine.range.end);
}

function respond(client: net.Socket, message: string) {
  if (!client.destroyed) client.write(message);
}

// Protocol

function decodeRequest(line: string): EditRequest | null {
  const parts = line.split("|");
  if (parts.length != 4 || parts[0] != "EDIT") return null;

  const [, requestPath, oldContent, newContent] = parts;
  return { path: decode(requestPath), oldContent: decode(oldContent), newContent: decode(newContent) };
}

function encode(value: string): string {
  return value.replace(/\|/g, "\\|").replace(/\n/g, "\\n");
}

function decode(value: string): string {
  return value.replace(/\\n/g, "\n").replace(/\\\|/g, "|");
}
