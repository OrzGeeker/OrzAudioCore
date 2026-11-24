# JNI resolves these names at runtime; keep them under minification.
-keep class com.orzgeeker.audiocore.OrzAudioCore { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
