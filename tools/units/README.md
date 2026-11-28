# tools/units/ — 盒子开机自启的 systemd unit（实测快照）

两份文件是 **121 / 123 两台盒子上正在跑的原件**，逐字节同步回仓库（2026-11-28，
两台 md5 一致），用来回答「盒子断电重启后靠什么自己回来」。

| 文件 | 装到 | 端口 | 生成脚本 |
|---|---|---|---|
| `lite-serve.service` | `/etc/systemd/system/` | `0.0.0.0:8765`（serve 常驻 agent） | `tools/serve_service.sh install` |
| `lite-setup.service` | `/etc/systemd/system/` | `0.0.0.0:8080`（API Key 初始化页） | `tools/setup_service.sh install` |

## 权威源不是这里的文件

**unit 由脚本生成，不手改。** 这里的快照只用于审计、拷到别的机器、以及 `diff` 对照。
路径/用户/端口在脚本里参数化，本文件里是盒子的取值（`root` + `/root/.local/share/lite`）：

```bash
sudo ./tools/serve_service.sh dry-run          # 只看 unit 文本，不碰系统
sudo ./tools/serve_service.sh install           # 写 unit + enable --now
sudo ./tools/setup_service.sh install
```

换机器/换用户时**别 cp 这两份文件**，改跑上面两条命令（`--user/--host/--port/--dir` 可覆盖）。

## 判「真自启」的三个证据

`is-active` 不算数——手工 `start` 的也 active。要同时满足：

```bash
systemctl is-enabled lite-serve lite-setup     # 都得是 enabled
ls -l /etc/systemd/system/multi-user.target.wants/lite-*.service   # 软链齐
sudo reboot && sleep 80 && systemctl is-active lite-serve lite-setup
```

`enabled` 但缺 wants 软链 = 起不来；`enabled` + 软链但 `Condition*`/`Assert*` 命不中 =
静默跳过（用 `systemd-analyze verify` 排）。121 曾经是 `disabled`：unit 建了没 enable，
等于手动开关，断电后 8765 空着等人 ssh 进去拉。

## 装好之后别用 serve_up.sh 停

systemd 接管后 `serve_up.sh stop`（写 `.stop` + 收进程组）会被 `Restart=always` 立刻拉回来，
看着像「停不掉」。停用 `systemctl stop`。
