package kha.netsync;

import haxe.io.Bytes;
import kha.Scheduler;

@:headerCode("
#include <kinc/network/socket.h>
")
@:headerClassCode("kinc_socket_t socket;")
class Network {
	var url: String;
	var port: Int;
	var bufferPos: Int;
	var buffer: Bytes;
	var tempBuffer: Bytes;
	var listener: Bytes->Void;
	var updateTaskId: Int;
	var open = false;

	public function new(url: String, port: Int, errorCallback: Void->Void, closeCallback: Void->Void) {
		this.url = url;
		this.port = port + 1; // TODO: This is somewhat ugly, but necessary to maintain both websocket and UPD connections at the same time (see also Server.hx)
		bufferPos = 0;
		buffer = Bytes.alloc(256); // TODO: Size
		tempBuffer = Bytes.alloc(256); // TODO: Size
		init(url, port);
		updateTaskId = Scheduler.addFrameTask(update, 0);
	}

	@:functionCode("
		kinc_socket_init(&socket);
		kinc_socket_options options;
		kinc_socket_options_set_defaults(&options);
		kinc_socket_set(&socket, \"127.0.0.1\", port, KINC_SOCKET_FAMILY_IP4, KINC_SOCKET_PROTOCOL_UDP);
		kinc_socket_open(&socket, &options);
	")
	function initSocket(port: Int): Void {}

	public function init(url: String, port: Int) {
		initSocket(port);
		open = true;
		send(Bytes.ofString("JOIN"), true); // TODO: Discuss, dependency with Server.hx
	}

	@:functionCode("
		// TODO: mandatory
		kinc_socket_send_url(&socket, url, port, (const unsigned char*)bytes->b->getBase(), bytes->length);
	")
	function sendSocket(bytes: Bytes): Void {}

	public function send(bytes: Bytes, mandatory: Bool): Void {
		if (open) {
			sendSocket(bytes);
		}
	}

	public function listen(listener: Bytes->Void): Void {
		this.listener = listener;
	}

	@:functionCode("
		kinc_socket_destroy(&socket);
	")
	function destroySocket(): Void {}

	public function close(): Void {
		if (!open) {
			return;
		}
		open = false;
		Scheduler.removeFrameTask(updateTaskId);
		destroySocket();
		listener = null;
	}

	function update() {
		if (!open) {
			return;
		}
		var received = getBytesFromSocket(tempBuffer);
		buffer.blit(bufferPos, tempBuffer, 0, received);
		bufferPos += received;
		// if (received > 0) trace("received " + received + " bytes");

		// TODO: Handle partial packets, don't choke on garbage
		if (listener != null && bufferPos > 0) {
			var result = Bytes.alloc(bufferPos);
			result.blit(0, buffer, 0, bufferPos);
			listener(result);
			bufferPos = 0;
		}
	}

	@:functionCode("
		unsigned int recAddr;
		unsigned int recPort;
		int size = kinc_socket_receive(&socket, (unsigned char*)inBuffer->b->getBase(), inBuffer->length, &recAddr, &recPort);
		if (size >= 0) {
			return size;
		}
		else {
			return 0;
		}
	")
	function getBytesFromSocket(inBuffer: Bytes): Int {
		return 0;
	}
}
