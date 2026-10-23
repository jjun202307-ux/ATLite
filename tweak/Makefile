THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ATLiteTweak

ATLiteTweak_FILES = Tweak.xm $(wildcard lib/lua53/src/*.c)
ATLiteTweak_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics ImageIO QuartzCore Vision
ATLiteTweak_CFLAGS = -fobjc-arc -Ilib/lua53/src -Wno-deprecated-declarations
ATLiteTweak_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
