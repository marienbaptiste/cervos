import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// LC3 decoder using dart:ffi — direct native call, no platform channel.
/// Same approach as opus_dart: synchronous, zero overhead.
class Lc3AudioDecoder {
  late final DynamicLibrary _lib;
  late final Pointer<Uint8> _decMem;
  late final Pointer<Void> _decoder;
  late final Pointer<Int16> _pcmOut;
  late final Pointer<Uint8> _lc3In;
  bool _initialized = false;

  static const int sampleRate = 24000;
  static const int frameUs = 10000;
  static const int frameSamples = 240;
  static const int maxFrameBytes = 128;

  // FFI function signatures
  late final int Function(int dtUs, int srHz) _decoderSize;
  late final Pointer<Void> Function(int dtUs, int srHz, int srPcmHz, Pointer<Uint8> mem) _setupDecoder;
  late final int Function(Pointer<Void> decoder, Pointer<Uint8> input, int nbytes,
      int fmt, Pointer<Int16> pcm, int stride) _decode;

  Future<void> init() async {
    if (_initialized) return;

    // Load the native library
    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('liblc3_decoder.so');
    } else {
      throw UnsupportedError('LC3 decoder only supported on Android');
    }

    // Bind functions
    _decoderSize = _lib.lookupFunction<
        Uint32 Function(Int32, Int32),
        int Function(int, int)>('lc3_decoder_size');

    _setupDecoder = _lib.lookupFunction<
        Pointer<Void> Function(Int32, Int32, Int32, Pointer<Uint8>),
        Pointer<Void> Function(int, int, int, Pointer<Uint8>)>('lc3_setup_decoder');

    _decode = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Int32, Pointer<Int16>, Int32),
        int Function(Pointer<Void>, Pointer<Uint8>, int, int, Pointer<Int16>, int)>('lc3_decode');

    // Allocate memory
    final memSize = _decoderSize(frameUs, sampleRate);
    _decMem = malloc<Uint8>(memSize);
    _pcmOut = malloc<Int16>(frameSamples);
    _lc3In = malloc<Uint8>(maxFrameBytes);

    // Setup decoder
    _decoder = _setupDecoder(frameUs, sampleRate, 0, _decMem);
    if (_decoder == nullptr) {
      throw Exception('LC3 decoder setup failed');
    }

    _initialized = true;
  }

  /// Decode a single LC3 frame to PCM. Synchronous, no platform channel.
  Int16List? decode(Uint8List lc3Data) {
    if (!_initialized) return null;

    // Copy input to native memory
    final inBytes = _lc3In.asTypedList(maxFrameBytes);
    inBytes.setRange(0, lc3Data.length, lc3Data);

    // Decode: fmt=0 is LC3_PCM_FORMAT_S16
    final err = _decode(_decoder, _lc3In, lc3Data.length, 0, _pcmOut, 1);

    if (err < 0) {
      // PLC on error
      _decode(_decoder, nullptr, 0, 0, _pcmOut, 1);
    }

    // Copy output
    return Int16List.fromList(_pcmOut.asTypedList(frameSamples));
  }

  /// Batch decode — just calls decode() in a loop (already synchronous).
  Int16List? decodeBatch(List<Uint8List> frames) {
    if (!_initialized || frames.isEmpty) return null;
    final out = Int16List(frames.length * frameSamples);
    int offset = 0;
    for (final frame in frames) {
      final pcm = decode(frame);
      if (pcm != null) {
        out.setRange(offset, offset + frameSamples, pcm);
      }
      offset += frameSamples;
    }
    return out;
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    malloc.free(_decMem);
    malloc.free(_pcmOut);
    malloc.free(_lc3In);
    _initialized = false;
  }
}

// Simple malloc/free using dart:ffi
final malloc = _Malloc();

class _Malloc {
  late final Pointer<T> Function<T extends NativeType>(int byteCount) _allocate;
  late final void Function(Pointer<Void>) _free;

  _Malloc() {
    final stdlib = Platform.isAndroid
        ? DynamicLibrary.open('libc.so')
        : DynamicLibrary.process();
    _allocate = <T extends NativeType>(int byteCount) {
      final f = stdlib.lookupFunction<
          Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)>('malloc');
      return f(byteCount).cast<T>();
    };
    _free = stdlib.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('free');
  }

  Pointer<T> call<T extends NativeType>(int byteCount) => _allocate<T>(byteCount);
  void free(Pointer p) => _free(p.cast<Void>());
}
