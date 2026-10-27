TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := HomeManager
HomeManager_FILES := Tweak.xm
HomeManager_CFLAGS := -fobjc-arc -fblocks -Wno-deprecated-declarations
HomeManager_FRAMEWORKS := UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
