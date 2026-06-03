# CLAUDE.md — HarmonyGIS 项目记忆

## 我是谁
- **GitHub 账号**: lovechengbao
- **运营环境**: Android Termux → PRoot Alpine Linux aarch64
- **Code 模型偏好**: deepseek-v4-pro

## 项目概述
- **HarmonyGIS**: 基于 OpenHarmony API 11 的 GIS 应用
- **技术栈**: ArkTS + ArkUI（声明式 UI）+ Hvigor 构建
- **GitHub 仓库**: https://github.com/lovechengbao/HarmonyGIS.git
- **许可证**: MIT

## 当前状态
- ✅ GitHub 仓库已创建并关联
- ✅ 项目骨架已搭建（entry, AppScope, hvigor, build-profile）
- ✅ 代码已精简为空白骨架
- ⏳ 功能待开发 — 用户后续会提出需求

## 项目结构
```
HarmonyGIS/
├── entry/src/main/ets/     ← ArkTS 源码（当前为空骨架）
├── AppScope/               ← 应用配置
├── hvigor/                 ← 构建配置
├── build-profile.json5     ← 项目构建配置
└── oh-package.json5        ← 包管理
```

## 开发须知
- 不能安装 DevEco Studio（Android 环境），只能编辑代码
- 使用 HTTPS 协议进行 Git 操作（gh CLI 已认证）
- 无需每次重新登录 GitHub（token 持久化在 ~/.config/gh/hosts.yml）
