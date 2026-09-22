SHELL := /bin/bash
PROJECT := TableLite.xcodeproj
SCHEME := TableLite
BUILD_DIR := $(CURDIR)/.build
CONFIG ?= Debug

.PHONY: help deps gen build run test smoke dist clean distclean doctor db db-reset db-stop db-shell

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

deps: ## 检查 Homebrew 依赖并生成 Configs/Local.xcconfig
	@./scripts/check-deps.sh
	@./scripts/gen-local-xcconfig.sh

gen: deps ## 用 XcodeGen 生成 Xcode 工程
	@echo "==> xcodegen generate"
	@xcodegen generate

build: gen ## 构建 .app
	@echo "==> xcodebuild ($(CONFIG))"
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIG)" \
		-derivedDataPath "$(BUILD_DIR)" \
		-quiet \
		build

run: build ## 构建并启动
	@open "$(BUILD_DIR)/Build/Products/$(CONFIG)/TableLite.app"

test: gen ## 跑单元测试
	@./scripts/check-imports.sh
	@echo "==> xcodebuild test"
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(BUILD_DIR)" \
		-quiet \
		test

smoke: build ## 访问层端到端冒烟验证（自动起 Docker MySQL）
	@./scripts/smoke/run.sh

db: ## 起一个常驻的 Docker MySQL 供手工测试（首次自动灌示例数据）
	@./scripts/dev/db.sh up

db-reset: ## 重灌手工测试库的示例数据（丢弃手工改过的数据）
	@./scripts/dev/db.sh reset

db-stop: ## 停掉手工测试库并删除数据
	@./scripts/dev/db.sh down

db-shell: ## 进手工测试库的 mysql 客户端
	@./scripts/dev/db.sh shell

dist: ## 构建 Release 并打包成可分发的 zip
	@./scripts/package-dist.sh

doctor: deps ## 打印依赖与链接情况，排查构建问题
	@echo "== otool -L libmysqlclient =="
	@otool -L "$$(brew --prefix mysql-client)/lib/libmysqlclient.dylib" || true
	@echo
	@echo "== LC_RPATH =="
	@otool -l "$$(brew --prefix mysql-client)/lib/libmysqlclient.dylib" 2>/dev/null \
		| grep -A2 LC_RPATH || echo "(无 LC_RPATH)"

clean: ## 清理构建产物
	@rm -rf "$(BUILD_DIR)"

distclean: clean ## 清理构建产物 + 生成的工程与配置
	@rm -rf "$(PROJECT)" Configs/Local.xcconfig
