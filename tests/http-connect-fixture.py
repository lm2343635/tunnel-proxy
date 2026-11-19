"""Disposable local CONNECT relay for recovery tests; never alters system proxies."""
import select
import socket
import sys
import threading

listen_port, host, target_port, interface = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]

def relay(client):
    upstream = None
    try:
        client.settimeout(5)
        request = b''
        while b'\r\n\r\n' not in request:
            request += client.recv(4096)
            if len(request) > 8192:
                return
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(interface))  # macOS IP_BOUND_IF
        upstream.settimeout(5)
        upstream.connect((host, target_port))
        client.sendall(b'HTTP/1.0 200 Connection established\r\n\r\n')
        client.settimeout(None)
        upstream.settimeout(None)
        while True:
            readable, _, _ = select.select([client, upstream], [], [], 2)
            for source in readable:
                data = source.recv(32768)
                if not data:
                    return
                (upstream if source is client else client).sendall(data)
    except (OSError, ValueError) as error:
        print(type(error).__name__, str(error), file=sys.stderr, flush=True)
    finally:
        client.close()
        if upstream:
            upstream.close()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', listen_port))
listener.listen()
while True:
    client, _ = listener.accept()
    threading.Thread(target=relay, args=(client,), daemon=True).start()
