import 'dart:async';

import 'package:camera/camera.dart';

import 'src/utils/logger.dart';

export 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

export 'package:face_camera/src/smart_face_camera.dart';
export 'package:face_camera/src/res/enums.dart';
export 'package:face_camera/src/models/detected_image.dart';
export 'package:face_camera/src/controllers/face_camera_controller.dart';

class FaceCamera {
  static List<CameraDescription> _cameras = [];

  /// Initialize device cameras
  static Future<void> initialize() async {
    /// Fetch the available cameras before initializing the app.
    try {
      _cameras = await availableCameras();
      print("Available cameras: ${_cameras.length}");
      print("${_cameras.map((c) => c.name).join(', ')}");
    } on CameraException catch (e) {
      print("Error fetching cameras: ${e.code} - ${e.description}");
      logError(e.code, e.description);
    }
  }

  /// Returns available cameras
  static List<CameraDescription> get cameras {
    return _cameras;
  }
}
