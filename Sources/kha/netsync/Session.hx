package kha.netsync;

import haxe.io.Bytes;
#if sys_server
import js.node.Http;
import js.Node;
#end
#if js
import js.Browser;
import js.html.BinaryType;
import js.html.WebSocket;
#end
import kha.System;

class Session {
	public static inline var START = 0;
	public static inline var ENTITY_UPDATES = 1;
	public static inline var CONTROLLER_UPDATES = 2;
	public static inline var REMOTE_CALL = 3;
	public static inline var PING = 4;
	public static inline var SESSION_ERROR = 5;
	public static inline var PLAYER_UPDATES = 6;

	public static inline var RPC_SERVER = 0;
	public static inline var RPC_ALL = 1;

	/**
		Server -> clients entity broadcast period, in seconds. Read by the
		Node backend's `synch()` loop on every tick, so games can change it
		at runtime.
	**/
	public static var networkSendRate: Float = 1 / 20;

	static var instance: Session = null;

	var entities: Map<Int, Entity> = new Map();
	var controllers: Map<Int, Controller> = new Map();

	public var maxPlayers: Int;
	public var currentPlayers: Int = 0;
	public var ping: Float = 1;

	var address: String;
	var port: Int;
	var startCallback: Void->Void;
	var refusedCallback: Void->Void;
	var resetCallback: Void->Void;
	#if sys_server
	var server: Server;
	var clients: Array<Client> = new Array();
	var current: Client;
	var isJoinable: Bool = false;
	#else
	var localClient: Client;

	public var network: Network;

	var updateTaskId: Int;
	var pingTaskId: Int;
	#end

	public var me(get, null): Client;

	function get_me(): Client {
		#if sys_server
		return current;
		#else
		return localClient;
		#end
	}

	public function new(maxPlayers: Int, address: String, port: Int) {
		instance = this;
		this.maxPlayers = maxPlayers;
		this.address = address;
		this.port = port;
	}

	public static function the(): Session {
		return instance;
	}

	public function addEntity(entity: Entity): Void {
		entities.set(entity._id(), entity);
	}

	public function addController(controller: Controller): Void {
		trace("Adding controller id " + controller._id());
		controller._inputBufferIndex = 0;
		controllers.set(controller._id(), controller);
	}

	#if sys_server
	private function send(): Bytes {
		var size = 0;
		for (entity in entities) {
			size += entity._size();
		}
		var offset = 0;
		var bytes = Bytes.alloc(size + 9);
		bytes.set(offset, ENTITY_UPDATES);
		offset += 1;
		bytes.setDouble(offset, Scheduler.time());
		offset += 8;
		for (entity in entities) {
			entity._send(offset, bytes);
			offset += entity._size();
		}

		return bytes;
	}
	#end

	public function sendControllerUpdate(id: Int, bytes: haxe.io.Bytes) {
		#if !sys_server
		if (controllers.exists(id)) {
			if (controllers[id]._inputBuffer.length < controllers[id]._inputBufferIndex + 4 + bytes.length) {
				var newBuffer = Bytes.alloc(controllers[id]._inputBufferIndex + 4 + bytes.length);
				newBuffer.blit(0, controllers[id]._inputBuffer, 0, controllers[id]._inputBufferIndex);
				controllers[id]._inputBuffer = newBuffer;
			}

			controllers[id]._inputBuffer.setInt32(controllers[id]._inputBufferIndex, bytes.length);
			controllers[id]._inputBuffer.blit(controllers[id]._inputBufferIndex + 4, bytes, 0, bytes.length);
			controllers[id]._inputBufferIndex += (4 + bytes.length);
		}
		#end
	}

	function sendPing() {
		#if !sys_server
		var bytes = haxe.io.Bytes.alloc(5);
		bytes.set(0, kha.netsync.Session.PING);
		bytes.setFloat(1, Scheduler.realTime());

		sendToServer(bytes);
		#end
	}

	function sendPlayerUpdate() {
		#if sys_server
		currentPlayers = clients.length;
		var bytes = haxe.io.Bytes.alloc(5);
		bytes.set(0, PLAYER_UPDATES);
		bytes.setInt32(1, currentPlayers);

		sendToEverybody(bytes);
		#end
	}

	public function receive(bytes: Bytes, client: Client = null): Void {
		#if sys_server
		switch (bytes.get(0)) {
			case CONTROLLER_UPDATES:
				var id = bytes.getInt32(1);
				// Bytes 5..21 (client timestamp + window size + rotation) are
				// ignored in this build. We used to feed them through
				// processEventRetroactively() + Scheduler.warp(), which made
				// the server's tick rate scale with the client's frame rate
				// and choked the event loop. Inputs are now applied
				// immediately and the simulation stays authoritative.
				if (controllers.exists(id)) {
					current = client;
					var offset = 22;
					while (offset < bytes.length) {
						var length = bytes.getInt32(offset);
						controllers[id]._receive(bytes.sub(offset + 4, length));
						offset += (4 + length);
					}
					current = null;
				}
			case REMOTE_CALL:
				processRPC(bytes);
			case PING:
				// PONG, i.e. just return the packet to the client
				if (client != null)
					client.send(bytes, false);
		}
		#else
		switch (bytes.get(0)) {
			case START:
				var index = bytes.get(1);
				localClient = new LocalClient(index);
				// Do NOT reset/warp the client scheduler from server time -
				// it stomps on the host app's frame tasks and makes input
				// feel laggy. Client time stays monotonic.
				startCallback();
			case ENTITY_UPDATES:
				var offset = 9;
				for (entity in entities) {
					entity._receive(offset, bytes);
					offset += entity._size();
				}
			// (server-side simulation time in bytes 1..8 ignored)
			case REMOTE_CALL:
				switch (bytes.get(1)) {
					case RPC_SERVER:
						// Mainly a safeguard, packets with RPC_SERVER should not be received here
					case RPC_ALL:
						executeRPC(bytes);
				}
			case PING:
				var sendTime = bytes.getFloat(1);
				ping = Scheduler.realTime() - sendTime;
			case SESSION_ERROR:
				refusedCallback();
				close();
			case PLAYER_UPDATES:
				currentPlayers = bytes.getInt32(1);
		}
		#end
	}

	#if sys_server
	public function processRPC(bytes: Bytes) {
		switch (bytes.get(1)) {
			case RPC_SERVER:
				executeRPC(bytes);
			case RPC_ALL:
				sendToEverybody(bytes);
				executeRPC(bytes);
		}
	}
	#end

	function executeRPC(bytes: Bytes) {
		var args = new Array<Dynamic>();
		var syncId = bytes.getInt32(2);
		var index: Int = 6;

		var classnamelength = bytes.getUInt16(index);
		index += 2;
		var classname = "";
		for (i in 0...classnamelength) {
			classname += String.fromCharCode(bytes.get(index));
			++index;
		}

		var methodnamelength = bytes.getUInt16(index);
		index += 2;
		var methodname = "";
		for (i in 0...methodnamelength) {
			methodname += String.fromCharCode(bytes.get(index));
			++index;
		}

		while (index < bytes.length) {
			var type = bytes.get(index);
			++index;
			switch (type) {
				case 0x42: // B
					var value: Bool = bytes.get(index) == 1;
					++index;
					trace("Bool: " + value);
					args.push(value);
				case 0x46: // F
					var value: Float = bytes.getDouble(index);
					index += 8;
					trace("Float: " + value);
					args.push(value);
				case 0x49: // I
					var value: Int = bytes.getInt32(index);
					index += 4;
					trace("Int: " + value);
					args.push(value);
				case 0x53: // S
					var length = bytes.getUInt16(index);
					index += 2;
					var str = "";
					for (i in 0...length) {
						str += String.fromCharCode(bytes.get(index));
						++index;
					}
					trace("String: " + str);
					args.push(str);
				default:
					trace("Unknown argument type.");
			}
		}
		if (syncId == -1) {
			Reflect.callMethod(null, Reflect.field(Type.resolveClass(classname), methodname + "_remotely"), args);
		}
		else {
			Reflect.callMethod(SyncBuilder.objects[syncId], Reflect.field(SyncBuilder.objects[syncId], methodname + "_remotely"), args);
		}
	}

	public function waitForStart(callback: Void->Void, refuseCallback: Void->Void, errorCallback: Void->Void, closeCallback: Void->Void,
			resCallback: Void->Void): Void {
		startCallback = callback;
		refusedCallback = refuseCallback;
		resetCallback = resCallback;
		#if sys_server
		isJoinable = true;
		#if direct_connection
		trace("Starting server at " + port + ".");
		#end
		server = new Server(port);
		server.onConnection(function(client: Client) {
			if (!isJoinable) {
				var bytes = Bytes.alloc(1);
				bytes.set(0, SESSION_ERROR);
				client.send(bytes, true);
				return;
			}

			clients.push(client);
			current = client;

			Node.console.log(clients.length + " client" + (clients.length > 1 ? "s " : " ") + "connected.");
			sendPlayerUpdate();

			client.receive(function(bytes: Bytes) {
				receive(bytes, client);
			});

			client.onClose(function() {
				Node.console.log("Removing client " + client.id + ".");
				clients.remove(client);
				sendPlayerUpdate();
				// isJoinable is intentionally not reset here immediately, as late joining is currently unsupported
				if (clients.length == 0) {
					reset();
				}
			});

			if (clients.length >= maxPlayers) {
				isJoinable = false;
				Node.console.log("Starting game.");
				var index = 0;
				for (c in clients) {
					trace("Starting client " + c.id);
					var bytes = Bytes.alloc(2);
					bytes.set(0, START);
					bytes.set(1, index);
					c.send(bytes, true);
					++index;
				}
				Scheduler.resetTime();
				startCallback();
			}
		});
		#else
		network = new Network(address, port, errorCallback, function() {
			closeCallback();
			reset();
		});
		network.listen(function(bytes: Bytes) {
			receive(bytes);
		});
		// Flush input on a fixed 60Hz cadence regardless of client refresh
		// rate. addFrameTask on a 120/144Hz display would otherwise send
		// twice as many input packets and double the server's CPU load.
		updateTaskId = Scheduler.addTimeTask(update, 0, 1 / 60);
		ping = 1;
		pingTaskId = Scheduler.addTimeTask(sendPing, 0, 1);
		#end
	}

	public function close(): Void {
		#if !sys_server
		Scheduler.removeTimeTask(updateTaskId);
		Scheduler.removeTimeTask(pingTaskId);
		if (network != null) {
			network.close();
			network = null;
		}
		#end
	}

	function reset() {
		#if sys_server
		isJoinable = true;
		server.reset();
		#else
		Scheduler.removeTimeTask(updateTaskId);
		Scheduler.removeTimeTask(pingTaskId);
		if (network != null) {
			network.close();
			network = null;
		}
		#end
		currentPlayers = 0;
		ping = 1;
		controllers = new Map();
		entities = new Map();
		resetCallback();
	}

	public function update(): Void {
		#if sys_server
		var bytes = send();
		sendToEverybody(bytes);
		#else
		for (controller in controllers) {
			if (controller._inputBufferIndex > 0) {
				var bytes = haxe.io.Bytes.alloc(22 + controller._inputBufferIndex);
				bytes.set(0, kha.netsync.Session.CONTROLLER_UPDATES);
				bytes.setInt32(1, controller._id());
				bytes.setDouble(5, Scheduler.time());
				bytes.setInt32(13, System.windowWidth(0));
				bytes.setInt32(17, System.windowHeight(0));
				bytes.set(21, 0); // System.screenRotation.getIndex());

				bytes.blit(22, controller._inputBuffer, 0, controller._inputBufferIndex);

				sendToServer(bytes);
				controller._inputBufferIndex = 0;
			}
		}
		#end
	}

	#if sys_server
	public function sendToEverybody(bytes: Bytes): Void {
		for (client in clients) {
			client.send(bytes, false);
		}
	}
	#end

	#if !sys_server
	public function sendToServer(bytes: Bytes): Void {
		network.send(bytes, false);
	}
	#end
}
