#!/bin/bash

export MACOSX_DEPLOYMENT_TARGET='10.13'
python3 platforms/apple/build_xcframework.py \
--iphoneos_deployment_target 9.0 \
--disable-swift --disable-bitcode \
--build_only_specified_archs \
--iphoneos_archs arm64 \
--without calib3d \
--without contrib \
--without dnn \
--without features2d \
--without flann \
--without gapi \
--without gpu \
--without highgui \
--without java \
--without js \
--without legacy \
--without ml \
--without nonfree \
--without objc \
--without objdetect \
--without photo \
--without python \
--without stitching \
--without ts \
--without video \
--without videoio \
--without videostab \
--without world \
--disable PROTOBUF \
--disable WEBP \
--disable PNG \
--disable TIFF \
--disable OPENJPEG \
--disable QUIRC \
--disable IPP \
--out build_min
