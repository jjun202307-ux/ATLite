THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak app probe

include $(THEOS_MAKE_PATH)/aggregate.mk
