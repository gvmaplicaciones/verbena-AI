import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Función top-level (requerida por `compute()` para correr en isolate
/// separado). image_picker_android copia el tag EXIF de orientación sin
/// rotar píxeles (ImageResizer.java usa BitmapFactory.decodeFile que ignora
/// EXIF, luego ExifDataCopier.copyExif copia TAG_ORIENTATION al archivo
/// nuevo). decodeJpg aplica la rotación al pixel buffer; encodeJpg graba sin
/// tag de rotación (orientation=1) -- Replicate ve píxeles ya bien
/// orientados. Usada por cualquier picker de cámara/galería (foto principal,
/// segunda foto, prendas del Armario).
Uint8List normalizeJpegOrientation(Uint8List bytes) {
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return bytes;
  return img.encodeJpg(decoded, quality: 90);
}
