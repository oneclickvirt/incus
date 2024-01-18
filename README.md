# incus

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2Fincus&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

## 更新

2024.01.16

- 增加[自编译](https://github.com/oneclickvirt/incus_images)部分的镜像筛选，加速容器的创建，默认选择顺序：自编译 > 官方 > 清华源
- 解决了部分旧系统在官方系统镜像中不存在的问题，可使用自编译的旧系统镜像
- 更改默认的物理卷类型，以保证容器的硬盘大小得到限制

[更新日志](CHANGELOG.md)

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 incus 分区内容

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs

## Sponsor

Thanks to [dartnode](https://dartnode.com/?via=server) for compilation support.

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/incus.svg?background=%23FFFFFF&axis=%23333333&line=%236b63ff)](https://starchart.cc/oneclickvirt/incus)
