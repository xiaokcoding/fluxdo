## v0.1.11

- chore: CI 修复

- ✨ Callout 显示优化

- ✨ 话题头部排版优化

- ✨ 首页底栏顶栏显示隐藏优化

- ✨ 相关链接显示

- 🐛 修复投票不显示查看结果按钮，fix #13

- ✨ 恢复完整的 pangu，提供降标安全保护，close #18

- ✨ 切图体验优化

- ✨ 搜索记录显示，错误消息处理，fix 23，close #24

- 🐛 Tag 兼容补充

- ✨ 排版优化简化

- ✨ 构建 ipa

## v0.1.10

- 🚑️ 兼容新的 api 结构，解决无法显示话题详情的问题（fix #20）

- ✨ 图片查看器图片过渡显示优化

- 🐛 修复话题详情嵌套视图滚动会显示隐藏底栏的问题

- ✨ 底栏滑动自动隐藏

- ✨ 骨架屏显示优化

- ✨ 长按预览功能

## v0.1.9

- 🐛 话题详情页面 bar 背景颜色切换错误修复

- ✨ 匿名分享功能实现，(close #15)

- ✨ 话题编辑功能，(close #17)

- ✨ 支持混排优化，(close #16)

- ✨ 修改回复主贴为等同回复话题，(close #14)

- ✨ 支持删除线编辑，(close #10)

- ✨ 时间解析优化，(fix #10)

- 📝 添加项目提示词

- 🐛 修复 LDC 余额显示错误，(fix #12)

- ✨ 兼容聊天记录引用卡片

- ✨ 登录登出体验优化

- 📦️ 依赖更新

- ✨ 采用更真实的设备 ua

- ✨ 图片查看优化

- ✨ 公式内容显示支持

- ✨ 图片上传体验优化，(close #8)

- ✨ 帖子删除功能，(close #6)

- 🐛 修复相对路径图片不加载的问题，(fix #3)

- ✨ 快问快答话题兼容

- ✨ 优化图片查看页面状态栏显示

- ✨ 优化过盾流程，仅不影响操作的放到后台过盾，并在网络设置中支持手动过盾

## v0.1.8

- ✨ 添加 CIRA Canadian Shield 为内置 DOH 服务，（close #5）

- 🚑️ CF 过盾体验优化，解决启动时遇到盾会无法启动的问题

- ✨ 热门回复/只看题主体验优化

- ✨ 大屏显示优化

## v0.1.7

- ✨ UA 修改静态值，修复无法使用谷歌登录

- ⚡️ CF 过盾优化与日志导出

- ⚡️ 优化大屏使用体验

- ✨ 代码块显示优化

- 🐛 修复发送提示不会自动消失，(fixes #2)

- ✨ 只看题主功能实现

- 🐛 跳转问题修复

- 🐛 Mac 构建修复

## v0.1.6

- ✨ 大图查看支持隐藏功能按钮、状态栏

- ✨ 贴内图片支持分享

- 🐛 修复分享完成后不能回到当前应用的问题

- ✨ 优化大图查看体验

- ✨ 用户资料页面头像支持大图查看

- ✨ 优化提及块样式

- ✨ 热门回复功能

- ✨ 显示题主[主]，本人[我]的标识

- 🐛 Onebox 显示优化

## v0.1.5

- ✨ 新的代码高亮实现

- ✨ Bar 点击标题展开 header

- ✨ 追踪链接点击

- ✨ OneBox 更多类型展示

- ✨ 话题订阅功能

## v0.1.4

- 🐛 修复话题投票时会直接刷新整个详情的问题

- 🐛 修复回到顶部概率触发刷新

- ✨ 支持帖子编辑功能和编辑时支持提及（@触发）

## v0.1.3

- feat: add PreloadedDataService for efficient initial data loading and configure Android build with ABI filtering.

- feat: implement topic detail page with scroll management, post display, and visibility tracking.

- feat: Add Discourse HTML content rendering with custom builders for various elements, including quote cards.

- feat: Implement Discourse poll rendering and voting, and configure Android build with signing and desugaring.

- feat: add user profile page with login/logout, user settings, and initial Android build configuration.

- feat: implement topic detail page with dynamic post loading, scrolling, and user activity tracking.

- feat: Implement core Discourse API service and topic detail page, including authentication, network handling, and screen tracking.

- feat: initialize Android build configuration and Flutter app entry point with service setup, theming, and localization.

## v0.1.2

- feat: implement topic creation flow with floating action button, navigation, and list refresh.

- feat: implement topic detail page with bi-directional post loading and new reply updates.

- feat: Add GitHub Actions workflow for automated Android build, release, and changelog generation, including supporting scripts.

## v0.1.1

- chore: bump version to 0.1.1

- Co-Authored-By: Release Script <noreply@github.com>

- feat: Implement comprehensive CI/CD pipeline for Android builds, including Rust DOH proxy compilation, artifact generation, changelog, and release automation.

## v0.1.0

- mvp

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
