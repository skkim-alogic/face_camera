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
      required FaceDetectorMode performanceMode,
      double? faceSizeThreshold,
      double? centerMargin
      }) async {
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
            _inputImageFromCameraImage(cameraImage, controller, orientations),
        imageSize: Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
        threshold: faceSizeThreshold,
        centerMargin: centerMargin
    );
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
      required FaceDetectorMode performanceMode,
      required Size imageSize,
      double? threshold,
      double? centerMargin
      }) async {
    if (visionImage == null) return null;
    final options = FaceDetectorOptions(
        enableLandmarks: true,
        enableTracking: true,
        enableClassification: true,
        performanceMode: performanceMode);
    final faceDetector = FaceDetector(options: options);
    try {
      final List<Face> faces = await faceDetector.processImage(visionImage);
      final faceDetect = _extractFace(faces, imageSize, threshold: threshold ?? 0.1, centerMargin: centerMargin ?? 0.4);
      return faceDetect;
    } catch (error) {
      debugPrint(error.toString());
      return null;
    }
  }

  static DetectedFace? _extractFace(List<Face> faces, Size imageSize, {double threshold = 0.1, double centerMargin = 0.4}) {
    if(faces.isEmpty) return null;
    Face? bestFace;
    double maxScore = 0.0;
    bool wellPositioned = false;

    for (Face face in faces) {

      if(!hasAllLandmarks(face)) continue;

      final Rect boundingBox = face.boundingBox;
      final double faceArea = boundingBox.width * boundingBox.height;
      final double imageArea = imageSize.width * imageSize.height; // 대략적인 전체 이미지 크기 유추

      // 1️⃣ 얼굴이 화면의 일정 비율 이상인지 확인 (크기 조건)
      bool isSizeOkay = (faceArea >= imageArea * threshold);
      if (!isSizeOkay) continue;

      // 2️⃣ 얼굴이 중앙에 위치하는지 확인
      final double imageCenterX = imageSize.height/2;
      final double imageCenterY = imageSize.width/2;
      final double faceCenterX = boundingBox.center.dx;
      final double faceCenterY = boundingBox.center.dy;

      final double xMargin = imageSize.width * centerMargin;
      final double yMargin = imageSize.height * centerMargin;

      print("중심 - X: $imageCenterX, Y: $imageCenterY");
      print("얼굴 - X: $faceCenterX, Y: $faceCenterY");

      bool isCentered = (faceCenterX >= imageCenterX - xMargin && faceCenterX <= imageCenterX + xMargin) &&
          (faceCenterY >= imageCenterY - yMargin && faceCenterY <= imageCenterY + yMargin);

      // 3️⃣ 머리 기울기 확인
      bool isHeadStraight = (face.headEulerAngleY!.abs() <= 10) && (face.headEulerAngleZ!.abs() <= 10);
      if (!isHeadStraight) continue;

      // 4️⃣ 최적의 얼굴 선택 (크기 + 중앙 여부 고려)
      double score = (faceArea / imageArea) + (isCentered ? 1.0 : 0.0); // 중앙에 있으면 점수 추가

      if (score > maxScore) {
        maxScore = score;
        bestFace = face;
        wellPositioned = isCentered;
      }
    }

    print("bestFace(Not): $bestFace");

    if(bestFace == null) return null;

    if(wellPositioned == false) {
      return null;
    }

    print("bestFace(Ok): $bestFace");

    return DetectedFace(
      wellPositioned: wellPositioned,
      face: bestFace
    );
  }

  static bool hasAllLandmarks(Face face) {
    // return face.landmarks.containsKey(FaceLandmarkType.leftEye) &&
    //     face.landmarks.containsKey(FaceLandmarkType.rightEye) &&
    //     face.landmarks.containsKey(FaceLandmarkType.noseBase) &&
    //     face.landmarks.containsKey(FaceLandmarkType.leftMouth) &&
    //     face.landmarks.containsKey(FaceLandmarkType.rightMouth);
    return face.landmarks[FaceLandmarkType.leftEye] != null &&
        face.landmarks[FaceLandmarkType.rightEye] != null &&
        face.landmarks[FaceLandmarkType.noseBase] != null &&
        face.landmarks[FaceLandmarkType.leftMouth] != null &&
        face.landmarks[FaceLandmarkType.rightMouth] != null;
  }
}
