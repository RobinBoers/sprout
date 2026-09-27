import * as vscode from "vscode";
import * as net from "net";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";

const SOCKET_PATH = path.join(os.tmpdir(), "sprout-vscode.sock");

interface PendingEdit {
  client: net.Socket;
  request: EditRequest;
}

interface EditRequest {
  path: string;
  oldContent: string;
  newContent: string;
}

const queue: PendingEdit[] = [];
let draining = false;

export function activate(context: vscode.ExtensionContext) {
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
    if (request) enqueue(client, request);
  });

  client.on("error", (err) => console.error("sprout-vscode: client socket error", err));
}

// Queue

function enqueue(client: net.Socket, request: EditRequest) {
  const pending: PendingEdit = { client, request };

  queue.push(pending);
  client.once("close", () => removePending(pending));

  drainQueue();
}

function removePending(pending: PendingEdit) {
  const index = queue.indexOf(pending);
  if (index != -1) queue.splice(index, 1);
}

async function drainQueue() {
  if (draining) return;
  draining = true;

  let next: PendingEdit | undefined;
  while ((next = queue.shift())) {
    await resolveEdit(next.client, next.request);
  }

  draining = false;
}

// Edit workflow

async function resolveEdit(client: net.Socket, request: EditRequest) {
  try {
    const { document, editor } = await presentEdit(request);
    const choice = await promptForApproval(request);

    if (choice == "Accept") {
      respond(client, "ACCEPTED\n");
    } else if (choice == "Accept with changes") {
      respond(client, `EDITED|${encode(editor.document.getText())}\n`);
    } else {
      await replaceContent(document, request.oldContent);
      respond(client, "REJECTED\n");
    }
  } catch (err) {
    console.error("sprout-vscode: failed to resolve edit", err);
    respond(client, "REJECTED\n");
  }
}

async function presentEdit(request: EditRequest) {
  const uri = vscode.Uri.file(request.path);

  const document = await vscode.workspace.openTextDocument(uri).then(
    (doc) => doc,
    () => vscode.workspace.openTextDocument({ content: request.oldContent }),
  );

  const editor = await vscode.window.showTextDocument(document, {
    preview: false,
    viewColumn: vscode.ViewColumn.Active,
  });

  await replaceContent(document, request.newContent);

  return { document, editor };
}

function promptForApproval(request: EditRequest) {
  const detail = `File: ${path.basename(request.path)}\nChanges: ${describeChanges(request)}`;

  return vscode.window.showInformationMessage(
    "Approve this edit?",
    { modal: false, detail },
    "Accept",
    "Accept with changes",
    "Reject",
  );
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

function describeChanges({ oldContent, newContent }: EditRequest): string {
  const diff = newContent.split("\n").length - oldContent.split("\n").length;

  if (diff == 0) return "No line count change";
  return diff > 0 ? `+${diff} lines` : `${diff} lines`;
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
