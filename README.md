# HarmonyGIS

基于 **OpenHarmony API 11** 的 GIS 地理信息系统应用。

## 项目简介

HarmonyGIS 是一个运行在 OpenHarmony 系统上的 GIS 应用，提供地图显示、图层管理、空间查询等基础地理信息服务功能。

## 技术栈

- **系统平台**: OpenHarmony API 11
- **开发语言**: ArkTS + C++
- **构建工具**: Hvigor
- **UI 框架**: ArkUI（声明式 UI）

## 项目结构

```
HarmonyGIS/
├── entry/                    # 主模块
│   ├── src/main/ets/         # ArkTS 源码
│   ├── src/main/resources/   # 资源文件
│   └── build-profile.json5   # 模块构建配置
├── AppScope/                 # 应用配置
├── hvigor/                   # 构建配置
├── build-profile.json5       # 项目构建配置
└── oh-package.json5          # 包管理配置
```

## 环境要求

- DevEco Studio 5.0+
- OpenHarmony SDK API 11
- Hvigor 构建工具

## 构建与运行

```bash
# 安装依赖
ohpm install

# 编译构建
hvigorw assembleHap

# 安装到设备
hdc install entry/build/default/output/default/entry-default-signed.hap
```

## 功能特性

- [ ] 地图基础显示（缩放、平移）
- [ ] 矢量图层管理
- [ ] 栅格地图加载
- [ ] 空间数据查询
- [ ] 坐标定位与标注
- [ ] GeoJSON 数据导入导出

## 许可证

MIT License
