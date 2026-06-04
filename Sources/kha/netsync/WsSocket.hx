package kha.netsync;

#if sys_server
extern class WsSocket {
	function send(data: Dynamic, ?cb: Dynamic->Void): Void;
	function close(?code: Int, ?reason: String): Void;
	function on(event: String, listener: Dynamic->Void): Void;
	var readyState(default, null): Int;
}
#end
