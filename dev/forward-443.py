#!/usr/bin/env python3
"""纯 TCP 端口转发：`<listen> → <target>`（dev 态用来补齐 443 那一跳）。

**为什么需要它**：发布态那条 `443 → 容器:3000` 是 docker 的端口映射给的（compose 里
`${GATEWAY_PORT}:3000`）；dev 态网关是个普通进程、按配置听高位端口（默认 3000），于是
agentd 的 endpoint（不带端口的域名，隐式 443）连不上。macOS 上绑 443 要 root，所以这里用
**一个 root 起的转发器**顶上 —— 网关本身仍以普通用户跑，`dev/configs/gateway` 的属主不受影响。

**只搬字节，不碰 TLS**：证书、信任锚、SNI 全部原样透传给网关，agent 侧地址也不必带端口，
所以 dev 与发布态在 agent 眼里是同一种形态。由 `dev/svc.sh start forward` 负责起停。

**代价（照实说）**：网关看到的对端地址会变成 `127.0.0.1` —— 所有 agent 挤进同一个限流桶，
日志里也看不出真实来源。要保真实源 IP 就别用它，改用 pf 的 `rdr`（内核级重定向，保源地址）。

用法（一般不用手敲，走 `svc.sh`）：
    sudo python3 forward-443.py 443 3000 --pidfile /tmp/wist-gateway-forward.pid
"""

import argparse
import asyncio
import os
import signal
import sys

CHUNK = 64 * 1024

# 后端连不上时不能每条连接都刷一行（agentd 会一直重试），但又不能安静得像没事发生：
# 打第一条（带“后端没在跑？”的提示），之后每 FAILURE_LOG_EVERY 条再提一次，
# 一旦重新连上就报一句“backend reachable again”。
FAILURE_LOG_EVERY = 100
_failures = 0

def note_backend_unreachable(err: OSError, peer: object, host: str, port: int) -> None:
    global _failures
    _failures += 1
    if _failures == 1 or _failures % FAILURE_LOG_EVERY == 0:
        print(
            f"connect {host}:{port} failed ({peer}): {err}" + (
                f"  [已连续 {_failures} 次]" if _failures > 1 else ""
            ),
            flush=True,
        )
        if _failures == 1:
            print(
                "  后端没在跑？（网关挂了 / 还没起来 / 不在这个端口）—— "
                "443 通不代表网关通，agent 侧会看到 transport error 而不是“拒连”。",
                flush=True,
            )


def note_backend_reachable(host: str, port: int) -> None:
    global _failures
    if _failures:
        print(f"backend {host}:{port} reachable again（先前后端不可达 {_failures} 次）", flush=True)
        _failures = 0


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """把一个方向搬完；对端 EOF 时**半关**写侧 —— TLS 的 close_notify 就是普通数据。"""
    try:
        while True:
            data = await reader.read(CHUNK)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, TimeoutError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, RuntimeError):
            pass


async def handle(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_host: str,
    target_port: int,
) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        up_reader, up_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as err:
        note_backend_unreachable(err, peer, target_host, target_port)
        client_writer.close()
        return
    note_backend_reachable(target_host, target_port)
    try:
        await asyncio.gather(
            pump(client_reader, up_writer),
            pump(up_reader, client_writer),
        )
    finally:
        for writer in (client_writer, up_writer):
            try:
                writer.close()
            except OSError:
                pass


async def serve(args: argparse.Namespace) -> None:
    server = await asyncio.start_server(
        lambda reader, writer: handle(reader, writer, args.target_host, args.target_port),
        args.bind,
        args.listen_port,
        reuse_address=True,
    )
    print(
        f"forward listening on {args.bind}:{args.listen_port} -> "
        f"{args.target_host}:{args.target_port} (plain TCP; TLS 由网关终止)",
        flush=True,
    )
    async with server:
        await server.serve_forever()


def main() -> int:
    parser = argparse.ArgumentParser(description="wist-gateway dev 端口转发")
    parser.add_argument("listen_port", type=int)
    parser.add_argument("target_port", type=int)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--pidfile", help="把自己的 pid 写到这里（root 起的进程，root 才能停）")
    args = parser.parse_args()

    if args.pidfile:
        with open(args.pidfile, "w", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")

        # 自己收尾：pidfile 是 root 建的，普通用户 rm 不掉，只能由它自己清。
        # 不清的话会留一个 root 所有的脏文件，下次起停时容易看不懂。
        def remove_pidfile(_signum, _frame):
            try:
                os.unlink(args.pidfile)
            except OSError:
                pass
            os._exit(0)

        signal.signal(signal.SIGTERM, remove_pidfile)
        signal.signal(signal.SIGINT, remove_pidfile)

    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
