# incus

[![Hits](https://hits.spiritlhl.net/incus.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

## 更新

2026.06.04

- 新增容器/虚拟机模板参数，支持 `web`、`db`、`dev`
- 新增实例快照、备份、恢复、迁移和 macvlan 配置辅助脚本
- 安装脚本同步分发 CT/VM 创建与运维辅助脚本，卸载脚本同步清理残留

[更新日志](CHANGELOG.md)

## 常用无交互入口 / Non-interactive helpers

统一使用 `export noninteractive=true` 指定无需交互模式。

Use `export noninteractive=true` for unattended runs.

```bash
export noninteractive=true
export INCUS_TEMPLATE=web
bash buildct.sh web1 1 512 5 20001 20002 20025 300 300 N debian12

export INCUS_OP_ACTION=backup
export INCUS_OP_INSTANCE=web1
bash instance_ops.sh

export INCUS_MACVLAN_ACTION=attach
export INCUS_MACVLAN_INSTANCE=web1
bash macvlan.sh

export SWAP_ACTION=reset
bash scripts/swap2.sh
```

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(English Docs)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 incus 分区内容

自修补容器镜像源：

[https://github.com/oneclickvirt/incus_images](https://github.com/oneclickvirt/incus_images)

## Introduce

English Docs:

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

Description of the **incus** partition contents in the documentation

Self-patching images sources:

[https://github.com/oneclickvirt/incus_images](https://github.com/oneclickvirt/incus_images)

## 友链

VPS融合怪测评脚本

https://github.com/oneclickvirt/ecs

https://github.com/spiritLHLS/ecs

## Sponsor

[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com?aff=bonus "Powered by DartNode - Free VPS for Open Source")

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/incus.svg?background=%23FFFFFF&axis=%23333333&line=%236b63ff)](https://starchart.cc/oneclickvirt/incus)
