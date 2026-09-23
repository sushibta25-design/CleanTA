ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

# Tweak: SpringBoard (server đóng app) + CarPlayApp (giao diện, chặn mở lại)
TWEAK_NAME = CleanTA
CleanTA_FILES = CleanTA.m
CleanTA_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
CleanTA_LIBRARIES = substrate
CleanTA_FRAMEWORKS = UIKit Foundation QuartzCore

# App: icon CleanTA trên Home (CarPlay qua bridge). Info.plist + icon nằm trong Resources/
APPLICATION_NAME = CleanTAApp
CleanTAApp_FILES = App/main.m
CleanTAApp_CFLAGS = -fobjc-arc
CleanTAApp_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/application.mk
