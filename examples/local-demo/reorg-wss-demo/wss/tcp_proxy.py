#!/usr/bin/env python3
import argparse
import signal
import socket
import threading


parser = argparse.ArgumentParser()
parser.add_argument("--listen-port", type=int, required=True)
parser.add_argument("--upstream-port", type=int, required=True)
args = parser.parse_args()

connections = set()
connections_lock = threading.Lock()
stopping = threading.Event()


def close_socket(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def pump(source, destination):
    try:
        while not stopping.is_set():
            data = source.recv(65536)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    finally:
        close_socket(source)
        close_socket(destination)


def handle(client, client_id):
    upstream = None
    try:
        upstream = socket.create_connection(("127.0.0.1", args.upstream_port), timeout=5)
        upstream.settimeout(None)
        with connections_lock:
            connections.add(upstream)
        print(f"connection {client_id} established", flush=True)
        thread = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        thread.start()
        pump(client, upstream)
        thread.join(timeout=2)
    except OSError as error:
        print(f"connection {client_id} error: {error}", flush=True)
        close_socket(client)
        if upstream is not None:
            close_socket(upstream)
    finally:
        with connections_lock:
            connections.discard(client)
            if upstream is not None:
                connections.discard(upstream)
        print(f"connection {client_id} closed", flush=True)


listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", args.listen_port))
listener.listen()
listener.settimeout(0.2)
print(f"proxy 127.0.0.1:{args.listen_port} -> 127.0.0.1:{args.upstream_port}", flush=True)


def stop(_signum, _frame):
    stopping.set()
    close_socket(listener)
    with connections_lock:
        active = list(connections)
    for sock in active:
        close_socket(sock)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
client_id = 0
while not stopping.is_set():
    try:
        client, _ = listener.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    client_id += 1
    with connections_lock:
        connections.add(client)
    threading.Thread(target=handle, args=(client, client_id), daemon=True).start()
