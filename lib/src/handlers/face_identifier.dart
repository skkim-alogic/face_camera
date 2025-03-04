import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:face_camera/src/extension/nv21_converter.dart';

import '../models/detected_image.dart';

class FaceIdentifier {
  static Future<DetectedFace?> scanImage(
      {required CameraImage cameraImage,
      required CameraController? controller,
      required FaceDetectorMode performanceMode}) async {
    final orientations = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };

    DetectedFace? result;
    final face = await _detectFace(
        performanceMode: performanceMode,
        visionImage:
            _inputImageFromCameraImage(cameraImage, controller, orientations));
    if (face != null) {
      result = face;
    }

    return result;
  }

  static InputImage? _inputImageFromCameraImage(CameraImage image,
      CameraController? controller, Map<DeviceOrientation, int> orientations) {
    // get image rotation
    // it is used in android to convert the InputImage from Dart to Java
    // `rotation` is not used in iOS to convert the InputImage from Dart to Obj-C
    // in both platforms `rotation` and `camera.lensDirection` can be used to compensate `x` and `y` coordinates on a canvas
    final camera = controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          orientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        // front-facing
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // back-facing
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // get image format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    // validate format depending on platform
    // only supported formats:
    // * bgra8888 for iOS
    if (format == null ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) return null;
    if (image.planes.isEmpty) return null;

    final bytes = Platform.isAndroid
        ? image.getNv21Uint8List()
        : Uint8List.fromList(
            image.planes.fold(
                <int>[],
                (List<int> previousValue, element) =>
                    previousValue..addAll(element.bytes)),
          );

    // compose InputImage using bytes
    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used only in Android
        format: Platform.isIOS ? format : InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow, // used only in iOS
      ),
    );
  }

  static Future<DetectedFace?> _detectFace(
      {required InputImage? visionImage,
      required FaceDetectorMode performanceMode}) async {
    if (visionImage == null) return null;
    final options = FaceDetectorOptions(
        enableLandmarks: true,
        enableTracking: true,
        performanceMode: performanceMode);
    final faceDetector = FaceDetector(options: options);
    try {
      final List<Face> faces = await faceDetector.processImage(visionImage);
      final faceDetect = _extractFace(faces, threshold: 0.4);
      return faceDetect;
    } catch (error) {
      debugPrint(error.toString());
      return null;
    }
  }

  static _extractFace(List<Face> faces, {double threshold = 0.4, double centerMargin = 0.6}) {
    //List<Rect> rect = [];
    bool wellPositioned = faces.isNotEmpty;
    Face? detectedFace;
    Size? imageSize;

    for (Face face in faces) {
      // rect.add(face.boundingBox);
      detectedFace = face;

      // 얼굴 bounding box 크기 계산
      final Rect boundingBox = face.boundingBox;
      final double faceArea = boundingBox.width * boundingBox.height;

      print("faceArea------------ $faceArea");

      // 이미지 전체 크기 (최초 감지된 얼굴의 크기로 설정)
      imageSize ??= Size(boundingBox.width * 2, boundingBox.height * 2);
      final double imageArea = imageSize.width * imageSize.height;

      print("imageArea------------ $imageArea");
      print("imageAreaThreshold------------ ${imageArea * threshold}");
      print("faceArea > imageArea * threshold------------ ${faceArea < imageArea * threshold}");

      // 얼굴이 화면의 일정 비율 이상인지 확인
      if (faceArea < imageArea * threshold) {
        wellPositioned = false;
      }

      // 2️⃣ 얼굴이 중앙에 위치하는지 확인
      final double imageCenterX = imageSize.width / 2;
      final double imageCenterY = imageSize.height / 2;
      final double faceCenterX = boundingBox.center.dx;
      final double faceCenterY = boundingBox.center.dy;

      final double xMargin = imageSize.width * centerMargin;
      final double yMargin = imageSize.height * centerMargin;

      if (!(faceCenterX >= imageCenterX - xMargin && faceCenterX <= imageCenterX + xMargin &&
          faceCenterY >= imageCenterY - yMargin && faceCenterY <= imageCenterY + yMargin)) {
        wellPositioned = false;
      }


      // Head is rotated to the right rotY degrees
      if (face.headEulerAngleY! > 5 || face.headEulerAngleY! < -5) {
        wellPositioned = false;
      }

      // Head is tilted sideways rotZ degrees
      if (face.headEulerAngleZ! > 5 || face.headEulerAngleZ! < -5) {
        wellPositioned = false;
      }

      // If landmark detection was enabled with FaceDetectorOptions (mouth, ears,
      // eyes, cheeks, and nose available):
      final FaceLandmark? leftEar = face.landmarks[FaceLandmarkType.leftEar];
      final FaceLandmark? rightEar = face.landmarks[FaceLandmarkType.rightEar];
      final FaceLandmark? bottomMouth =
          face.landmarks[FaceLandmarkType.bottomMouth];
      final FaceLandmark? rightMouth =
          face.landmarks[FaceLandmarkType.rightMouth];
      final FaceLandmark? leftMouth =
          face.landmarks[FaceLandmarkType.leftMouth];
      final FaceLandmark? noseBase = face.landmarks[FaceLandmarkType.noseBase];
      if (leftEar == null ||
          rightEar == null ||
          bottomMouth == null ||
          rightMouth == null ||
          leftMouth == null ||
          noseBase == null) {
        wellPositioned = false;
      }

      if (face.leftEyeOpenProbability != null) {
        if (face.leftEyeOpenProbability! < 0.5) {
          wellPositioned = false;
        }
      }

      if (face.rightEyeOpenProbability != null) {
        if (face.rightEyeOpenProbability! < 0.5) {
          wellPositioned = false;
        }
      }

      if (wellPositioned) {
        break;
      }
    }

    return DetectedFace(
      wellPositioned: wellPositioned,
      face: detectedFace,
    );
  }
}
