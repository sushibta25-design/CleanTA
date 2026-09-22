ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = CleanTA
CleanTA_FILES = CleanTA.m
CleanTA_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
CleanTA_FRAMEWORKS = UIKit Foundation QuartzCore
include $(THEOS_MAKE_PATH)/tweak.mk
