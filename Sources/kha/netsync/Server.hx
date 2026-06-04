package kha.netsync;

import haxe.io.Bytes;
#if sys_server
import js.Node;
#end

#if sys_server
/** Subset of the `ws` library API we depend on. **/
@:jsRequire("ws", "WebSocketServer")
private extern class WsServer {
	function new(options: WsServerOptions);
	function on(event: String, listener: WsSocket->Void): Void;
}

private typedef WsServerOptions = {
	?port: Int,
	?host: String,
	?path: String,
	?perMessageDeflate: Bool,
}
#end

/**
	Minimal pure-WebSocket transport for `kha.netsync`. No HTTP server,
	no static file hosting — serve the html5 build elsewhere (the kha dev
	server on 4200 or any static host).
**/
class Server {
	#if sys_server
	private var wss: WsServer;
	private var lastId: Int = -1;

	#if !direct_connection
	private var clients: Map<Int, NodeProcessClient> = new Map();
	private var connectionCallback: Client->Void;
	#end
	#end
	public function new(port: Int) {
		#if sys_server
		#if direct_connection
		wss = new WsServer({port: port});
		Node.console.log('[netsync] websocket listening on $port');

		// Don't let a thrown error inside any per-socket handler take down
		// the whole server (and therefore reset every session).
		Node.process.on("uncaughtException", function(err) {
			Node.console.error("[netsync] uncaught: " + err);
		});
		#else
		Node.process.on("message", function(message) {
			var msg: String = message.message;
			switch (msg) {
				case "connect":
					var id: Int = message.id;
					var client = new NodeProcessClient(id);
					clients[id] = client;
					connectionCallback(client);
				case "disconnect":
					var id: Int = message.id;
					var client = clients[id];
					client._close();
					clients.remove(id);
				case "message":
					var id: Int = message.id;
					var client = clients[id];
					client._message(message.data);
			}
		});
		#end
		#end
	}

	public function onConnection(connection: Client->Void): Void {
		#if sys_server
		#if direct_connection
		wss.on("connection", function(socket: WsSocket) {
			socket.on("error", function(err) {
				Node.console.error("[netsync] socket error: " + err);
			});
			++lastId;
			connection(new WebSocketClient(lastId, socket));
		});
		#else
		connectionCallback = connection;
		#end
		#end
	}

	public function reset(): Void {
		#if sys_server
		lastId = -1;
		#end
	}
}
