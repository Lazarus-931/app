.PHONY: build verify clean
.PHONY: xcode-generate xcode-build xcode-smoke xcode-lifecycle-smoke

XCODE_DERIVED_DATA ?= build/XcodeDerivedData

build:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py

verify:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --verify-only

verify-python:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --skip-install --verify-only

clean:
	rm -rf build dist

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
xcodebuild -project MLXPlatform.xcodeproj -scheme MLXVLMServer -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

xcode-smoke: xcode-build
$(XCODE_DERIVED_DATA)/Build/Products/Debug/MLXVLMServer.app/Contents/MacOS/MLXVLMServer --smoke-test

xcode-lifecycle-smoke: xcode-build
$(XCODE_DERIVED_DATA)/Build/Products/Debug/MLXVLMServer.app/Contents/MacOS/MLXVLMServer --lifecycle-smoke-test
