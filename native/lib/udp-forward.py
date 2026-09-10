#!/usr/bin/env python3
# =============================================================================
# udp-forward.py - 双向 UDP 转发器（免 root，socat 的纯 Python 替代）
#
# 用途：把容器对外主端口 SERVER_PORT/UDP 转发到星露谷游戏端口 24642。
# 为什么需要：星露谷游戏端口硬编码 24642，而简幻欢 AIO 容器只暴露一个
# SERVER_PORT；socat 在只读容器里 apt 装不上，于是用本脚本兜底。
#
# 双向语义：每个玩家客户端地址 -> 一条独立的到游戏的 UDP 通道（fork 模型），
# 游戏回包经该通道原路返回给对应玩家，避免单 socket 转发导致的回程错乱。
#
# 用法：python3 udp-forward.py <监听端口> <目标端口> [目标地址]
#   例：python3 udp-forward.py 33795 24642 127.0.0.1
# =============================================================================
import sys
import socket
import threading

if len(sys.argv) < 3:
    sys.stderr.write("usage: udp-forward.py <listen_port> <target_port> [target_host]\n")
    sys.exit(2)

LISTEN_PORT = int(sys.argv[1])
TARGET_PORT = int(sys.argv[2])
TARGET_HOST = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"

listen_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
listen_sock.bind(("0.0.0.0", LISTEN_PORT))

clients = {}          # (addr) -> per-client socket connected to target
lock = threading.Lock()


def pump_back(client_addr, client_sock):
    """读取游戏回包，转发给对应玩家。"""
    while True:
        try:
            data = client_sock.recv(65535)
        except Exception:
            break
        if not data:
            continue
        try:
            listen_sock.sendto(data, client_addr)
        except Exception:
            pass


def main():
    while True:
        data, addr = listen_sock.recvfrom(65535)
        with lock:
            cs = clients.get(addr)
            if cs is None:
                cs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                cs.connect((TARGET_HOST, TARGET_PORT))
                clients[addr] = cs
                t = threading.Thread(target=pump_back, args=(addr, cs), daemon=True)
                t.start()
        try:
            cs.send(data)
        except Exception:
            # 通道失效则重建
            with lock:
                try:
                    del clients[addr]
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
