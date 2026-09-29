# 本地 Theos 构建 (可选; CI 用 .github/workflows/build.yml 直接调 clang)
TARGET = iphone:clang:latest:15.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GZZ
GZZ_FILES = GZZ.m
GZZ_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
GZZ_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
