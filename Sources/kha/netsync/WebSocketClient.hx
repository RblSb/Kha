package kha.netsync;

import haxe.io.Bytes;
#if sys_server
import js.lib.ArrayBuffer;
import js.node.Buffer;
#end

class WebSocketClient implements Client {
	var myId: Int;
	#if sys_server
	var socket: WsSocket;
	#end

	#if sys_server
	public function new(id: Int, socket: WsSocket) {
		myId = id;
		this.socket = socket;
	}
	#else
	public function new(id: Int, socket: Dynamic) {
		myId = id;
	}
	#end

	public function send(bytes: Bytes, mandatory: Bool): Void {
		#if sys_server
		if (socket.readyState == 1) {
			socket.send(bytes.getData(), function(err) {});
		}
		#end
	}

	public function receive(receiver: Bytes->Void): Void {
		#if sys_server
		socket.on("message", function(message: Dynamic) {
			// `ws` delivers binary frames as a Node Buffer (a Uint8Array
			// view onto a shared ArrayBuffer pool). Slice out just this
			// frame's window so haxe.io.Bytes doesn't see neighbouring
			// frames' bytes.
			final buf: Buffer = cast message;
			final ab: ArrayBuffer = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
			receiver(Bytes.ofData(ab));
		});
		#end
	}

	public function onClose(close: Void->Void): Void {
		#if sys_server
		socket.on("close", function(_) close());
		#end
	}

	public function close(): Void {
		#if sys_server
		try {
			socket.close();
		}
		catch (_) {}
		#end
	}

	public var controllers(get, null): Array<Controller>;

	function get_controllers(): Array<Controller> {
		return null;
	}

	public var id(get, null): Int;

	function get_id(): Int {
		return myId;
	}
}
