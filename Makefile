SHELL := /bin/bash
PROJECT := TableLite.xcodeproj
SCHEME := TableLite
BUILD_DIR := $(CURDIR)/.build
CONFIG ?= Debug
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: help deps gen build run test smoke dist dist-install clean distclean doctor db db-reset db-stop db-shell

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

dist-install: dist ## 构建 Release 并安装到 ~/Applications（可用 INSTALL_DIR 覆盖）
	@echo "==> 安装到 $(INSTALL_DIR)/TableLite.app"
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/TableLite.app"
	@ditto "$(BUILD_DIR)/Build/Products/Release/TableLite.app" "$(INSTALL_DIR)/TableLite.app"
	@echo "  完成。启动：open \"$(INSTALL_DIR)/TableLite.app\""

doctor: deps ## 打印依赖与链接情况，排查构建问题
	@echo "== 静态链接库（App 直接链进二进制）=="
	@for spec in mysql-client:lib/libmysqlclient.a openssl@3:lib/libssl.a \
		openssl@3:lib/libcrypto.a zstd:lib/libzstd.a zlib-ng-compat:lib/libz.a; do \
		f="$$(brew --prefix $${spec%%:*})/$${spec#*:}"; \
		if [[ -f "$$f" ]]; then echo "  ✓ $$f"; else echo "  ✗ 缺失 $$f"; fi; \
	done
	@echo
	@echo "== 产物依赖（应为空；有输出说明退回了动态链接）=="
	@dir="$(BUILD_DIR)/Build/Products/$(CONFIG)/TableLite.app/Contents/MacOS"; \
	if [[ -f "$$dir/TableLite.debug.dylib" ]]; then bin="$$dir/TableLite.debug.dylib"; \
	elif [[ -f "$$dir/TableLite" ]]; then bin="$$dir/TableLite"; else bin=""; fi; \
	if [[ -z "$$bin" ]]; then \
		echo "  (还没构建，先 make build)"; \
	else \
		echo "  $$bin"; \
		otool -L "$$bin" | tail -n +2 | awk '{print $$1}' | grep '^/opt/homebrew/' || echo "  (无 Homebrew 引用)"; \
	fi
	@echo
	@echo "== 外部认证插件（连老服务器时才用到，见 13-open-questions.md L41）=="
	@ls "$$(brew --prefix mysql-client)/lib/plugin" 2>/dev/null || true

clean: ## 清理构建产物
	@rm -rf "$(BUILD_DIR)"

distclean: clean ## 清理构建产物 + 生成的工程与配置
	@rm -rf "$(PROJECT)" Configs/Local.xcconfig
