import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../../face_camera.dart';
import '../handlers/enum_handler.dart';
import '../handlers/face_identifier.dart';
import '../utils/logger.dart';
import 'face_camera_state.dart';
import 'dart:math' as math;

/// The controller for the [SmartFaceCamera] widget.
class FaceCameraController extends ValueNotifier<FaceCameraState> {
  /// Construct a new [FaceCameraController] instance.
  FaceCameraController({
    this.imageResolution = ImageResolution.medium,
    this.defaultCameraLens,
    this.defaultFlashMode = CameraFlashMode.auto,
    this.enableAudio = true,
    this.autoCapture = false,
    this.ignoreFacePositioning = false,
    this.orientation = CameraOrientation.portraitUp,
    this.performanceMode = FaceDetectorMode.fast,
    required this.onCapture,
    this.onFaceDetected,
    this.onFaceDetecting,
    this.faceSizeThreshold = 0.1,
    this.centerMargin = 0.4,
  }) : super(FaceCameraState.uninitialized());

  /// The desired resolution for the camera.
  final ImageResolution imageResolution;

  /// Use this to set initial camera lens direction.
  final CameraLens? defaultCameraLens;

  /// Use this to set initial flash mode.
  final CameraFlashMode defaultFlashMode;

  /// Set false to disable capture sound.
  final bool enableAudio;

  /// Set true to capture image on face detected.
  final bool autoCapture;

  /// Set true to trigger onCapture even when the face is not well positioned
  final bool ignoreFacePositioning;

  /// Use this to lock camera orientation.
  final CameraOrientation? orientation;

  /// Use this to set your preferred performance mode.
  final FaceDetectorMode performanceMode;

  /// Callback invoked when camera captures image.
  final void Function(File? image) onCapture;

  /// Callback invoked when camera detects face.
  final void Function(Face? face)? onFaceDetected;

  final void Function(Face? face, double faceLuminance, double frameLuminance)? onFaceDetecting;

  final double? faceSizeThreshold;

  final double? centerMargin;

  /// Gets all available camera lens and set current len
  void _getAllAvailableCameraLens() {
    int currentCameraLens = 0;
    final List<CameraLens> availableCameraLens = [];
    for (CameraDescription d in FaceCamera.cameras) {
      final lens = EnumHandler.cameraLensDirectionToCameraLens(d.lensDirection);
      if (lens != null && !availableCameraLens.contains(lens)) {
        availableCameraLens.add(lens);
      }
    }

    if (defaultCameraLens != null) {
      try {
        currentCameraLens = availableCameraLens.indexOf(defaultCameraLens!);
      } catch (e) {
        logError(e.toString());
      }
    }

    value = value.copyWith(
        availableCameraLens: availableCameraLens,
        currentCameraLens: currentCameraLens);
  }

  Future<void> _initCamera() async {
    final cameras = FaceCamera.cameras
        .where((c) =>
            c.lensDirection ==
            EnumHandler.cameraLensToCameraLensDirection(
                value.availableCameraLens[value.currentCameraLens]))
        .toList();

    if (cameras.isNotEmpty) {
      final cameraController = CameraController(cameras.first,
          EnumHandler.imageResolutionToResolutionPreset(imageResolution),
          enableAudio: enableAudio,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888);

      await cameraController.initialize().whenComplete(() {
        value = value.copyWith(
            isInitialized: true, cameraController: cameraController);
      });

      await changeFlashMode(value.availableFlashMode.indexOf(defaultFlashMode));

      await cameraController.lockCaptureOrientation(
          EnumHandler.cameraOrientationToDeviceOrientation(orientation));
    }

    startImageStream();
  }

  Future<void> changeFlashMode([int? index]) async {
    final newIndex =
        index ?? (value.currentFlashMode + 1) % value.availableFlashMode.length;
    await value.cameraController!
        .setFlashMode(EnumHandler.cameraFlashModeToFlashMode(
            value.availableFlashMode[newIndex]))
        .then((_) {
      value = value.copyWith(currentFlashMode: newIndex);
    });
  }

  /// The supplied [zoom] value should be between 1.0 and the maximum supported
  Future<void> setZoomLevel(double zoom) async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null) {
      return;
    }
    await cameraController.setZoomLevel(zoom);
  }

  Future<void> changeCameraLens() async {
    value = value.copyWith(
        currentCameraLens:
            (value.currentCameraLens + 1) % value.availableCameraLens.length);
    _initCamera();
  }

  Future<XFile?> takePicture() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      logError('Error: select a camera first.');
      return null;
    }

    if (cameraController.value.isTakingPicture) {
      logError('A capture is already pending');
      return null;
    }

    try {
      XFile file = await cameraController.takePicture();
      return file;
    } on CameraException catch (e) {
      _showCameraException(e);
      return null;
    }
  }

  void _showCameraException(CameraException e) {
    logError(e.code, e.description);
  }

  Future<void> startImageStream() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    if (!cameraController.value.isStreamingImages) {
      await cameraController.startImageStream(_processImage);
    }
  }

  Future<void> stopImageStream() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    if (cameraController.value.isStreamingImages) {
      await cameraController.stopImageStream();
    }
  }

  double _calculateLuminance(CameraImage image, Face? face) {
    if(face == null) {
      //YUV 포맷 기준 luminance 계산 (성능 최적화)
      final yPlane = image.planes[0].bytes;
      double sum = 0;
      for (int i = 0; i < yPlane.length; i += 2) {
        sum += yPlane[i].toDouble();
      }
      return sum / (yPlane.length ~/ 2);
    }


    debugPrint('Calculating luminance for face rect: ${face.boundingBox.center}');

    final yPlane = image.planes[0].bytes;

    // YUV420에서 Y 채널의 stride 고려
    final yStride = image.planes[0].bytesPerRow;

    final faceRect = face.boundingBox;

    // 얼굴 영역 좌표 변환 (정규화 → 픽셀 단위)
    final x = face.boundingBox.left.toInt().clamp(0, image.width-1);
    final y = face.boundingBox.top.toInt().clamp(0, image.height-1);
    final w = face.boundingBox.width.toInt().clamp(1, image.width-x);
    final h = face.boundingBox.height.toInt().clamp(1, image.height-y);

    double sum = 0;
    int pixelCount = 0;

    // 얼굴 영역만 순회 (성능을 위해 stride=2)
    for (int row = y; row < y + h; row += 2) {
      for (int col = x; col < x + w; col += 2) {
        final pos = row * yStride + col;
        if (pos < yPlane.length) {
          sum += yPlane[pos].toDouble();
          pixelCount++;
        }
      }
    }

    return pixelCount > 0 ? sum / pixelCount : 0;
  }

  void _processImage(CameraImage cameraImage) async {
    final CameraController? cameraController = value.cameraController;
    if (!value.alreadyCheckingImage) {
      value = value.copyWith(alreadyCheckingImage: true);
      try {
        await FaceIdentifier.scanImage(
                cameraImage: cameraImage,
                controller: cameraController,
                performanceMode: performanceMode,
                faceSizeThreshold: faceSizeThreshold,
                centerMargin: centerMargin
        )
            .then((result) async {
          value = value.copyWith(detectedFace: result);


          final frameLuminance = _calculateLuminance(cameraImage, null);

          final faceLuminance = _calculateLuminance(cameraImage, result?.face);

          onFaceDetecting?.call(result?.face, faceLuminance, frameLuminance);

          if (result != null) {
            try {
              if (result.face != null) {
                onFaceDetected?.call(result.face);
              }
              if (autoCapture &&
                  (result.wellPositioned || ignoreFacePositioning)) {
                captureImage();
              }
            } catch (e) {
              logError(e.toString());
            }
          }
        });
        value = value.copyWith(alreadyCheckingImage: false);
      } catch (ex, stack) {
        value = value.copyWith(alreadyCheckingImage: false);
        logError('$ex, $stack');
      }
    }
  }

  @Deprecated('Use [captureImage]')
  void onTakePictureButtonPressed() async {
    captureImage();
  }

  void captureImage() async {
    final CameraController? cameraController = value.cameraController;
    try {
      cameraController!.stopImageStream().whenComplete(() async {
        await Future.delayed(const Duration(milliseconds: 500));
        takePicture().then((XFile? file) {
          /// Return image callback
          if (file != null) {
            onCapture.call(File(file.path));
          }
        });
      });
    } catch (e) {
      logError(e.toString());
    }
  }

/*  void onViewFinderTap(TapDownDetails details, BoxConstraints constraints) {
    if (value.cameraController == null) {
      return;
    }

    final CameraController cameraController = value.cameraController!;

    final offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    cameraController.setExposurePoint(offset);
    cameraController.setFocusPoint(offset);
  }*/

  Future<void> initialize() async {
    _getAllAvailableCameraLens();
    _initCamera();
  }

  /// Enables controls only when camera is initialized.
  bool get enableControls {
    final CameraController? cameraController = value.cameraController;
    return cameraController != null && cameraController.value.isInitialized;
  }

  /// Dispose the controller.
  ///
  /// Once the controller is disposed, it cannot be used anymore.
  @override
  Future<void> dispose() async {
    final CameraController? cameraController = value.cameraController;

    if (cameraController != null && cameraController.value.isInitialized) {
      cameraController.dispose();
    }
    super.dispose();
  }
}
