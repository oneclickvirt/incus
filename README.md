# incus

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2Foneclickvirt%2Fincus&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)


## 更新

2024.01.15

- 迁移LXD项目至于incus项目
- 对无zfs的ubuntu系统增加处理
- 宿主机若系统重启，DNS自检测的守护进程增加ufw关闭防火墙的指令，避免重启后防火墙启动导致incus网络冲突

[更新日志](CHANGELOG.md)

## 待解决的问题

- LXC模板构建自定义的模板提前初始化好部分内容并发布到自己的镜像仓库中，避免原始模板过于干净导致初始化时间过长，以及支持一些旧版本的系统(centos7，centos8，debian8，debian9)，相关资料[1](https://github.com/lxc/lxc-ci/tree/main/images)、[2](https://github.com/lxc/distrobuilder)、[3](https://cloud.tencent.com/developer/article/2348016?areaId=106001)
- 使得宿主机支持更多的系统，不仅限于ubuntu和debian系做宿主机

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 incus 分区内容

## 友链

VPS融合怪测评脚本

https://github.com/spiritLHLS/ecs

## Stargazers over time
                        
## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/incus.svg?background=%23FFFFFF&axis=%23333333&line=%236b63ff)](https://starchart.cc/oneclickvirt/incus)

