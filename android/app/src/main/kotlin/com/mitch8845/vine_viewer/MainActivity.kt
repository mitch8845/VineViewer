package com.mitch8845.vine_viewer

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts Flutter, plus a small file picker -- images for the aerial, anything
 * for a spreadsheet import.
 *
 * The picker lives here rather than in a plugin on purpose. `file_picker` had to
 * be removed because its Gradle script applies the Kotlin Gradle Plugin, which
 * AGP 9 with Flutter's built-in Kotlin refuses to configure -- the same
 * incompatibility that forced the `path_provider_android` pin in pubspec.yaml.
 * That failure mode belongs to *plugins*: this module already compiles Kotlin
 * fine, so framework code here cannot hit it. Roughly fifty lines buys
 * independence from a whole class of build breakage.
 */
class MainActivity : FlutterActivity() {
    /** The Dart call waiting on a pick, if any. */
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> pick(result, MIME_IMAGE)
                    // Any file: a spreadsheet copied over USB often arrives
                    // typed as a generic binary, and filtering by the
                    // spreadsheet types would grey it out. Dart checks what
                    // it actually is.
                    "pickFile" -> pick(result, MIME_ANY)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pick(result: MethodChannel.Result, mime: String) {
        // Two taps arriving before the chooser opens would strand the first
        // Result forever, and an unanswered MethodChannel call never times out.
        if (pending != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }
        pending = result

        val open = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
        }

        try {
            startActivityForResult(open, REQUEST_PICK_IMAGE)
        } catch (_: ActivityNotFoundException) {
            // Fire OS ships a trimmed Android and does not always carry the
            // system document picker. ACTION_GET_CONTENT is the older, more
            // widely handled intent, and the gallery answers it.
            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
            }
            try {
                startActivityForResult(fallback, REQUEST_PICK_IMAGE)
            } catch (_: ActivityNotFoundException) {
                pending = null
                result.error("no_picker", "This device has no file picker.", null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_IMAGE) return
        deliver(if (resultCode == Activity.RESULT_OK) data?.data else null)
    }

    /**
     * Copies the chosen image somewhere Dart can read it and answers the call.
     *
     * A content URI is not a file path, and everything downstream -- the project
     * record, the canvas decoder -- works from real files. So the bytes are
     * copied out here. This lands in the cache directory, which Android may
     * clear at will; Dart moves it into the documents directory immediately,
     * where the aerial actually lives.
     */
    private fun deliver(uri: Uri?) {
        val result = pending ?: return
        pending = null

        if (uri == null) {
            // Cancelled. Not an error -- null means "the user changed their mind".
            result.success(null)
            return
        }

        try {
            val target = File(cacheDir, "picked/${System.currentTimeMillis()}")
            target.parentFile?.mkdirs()
            contentResolver.openInputStream(uri).use { input ->
                if (input == null) {
                    result.error("unreadable", "Could not open that file.", null)
                    return
                }
                target.outputStream().use { input.copyTo(it) }
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("copy_failed", e.message, null)
        }
    }

    private companion object {
        const val CHANNEL = "vineviewer/files"
        const val MIME_IMAGE = "image/*"
        const val MIME_ANY = "*/*"
        const val REQUEST_PICK_IMAGE = 4201
    }
}
