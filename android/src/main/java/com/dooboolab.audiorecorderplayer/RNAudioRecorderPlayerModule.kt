package com.dooboolab.audiorecorderplayer

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule.RCTDeviceEventEmitter
import com.facebook.react.modules.core.PermissionListener
import com.naman14.androidlame.AndroidLame
import com.naman14.androidlame.LameBuilder
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.*
import kotlin.math.abs
import kotlin.math.log10

class RNAudioRecorderPlayerModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), PermissionListener {
    private var audioFileURL = ""
    private var subsDurationMillis = 500
    private var _meteringEnabled = false

    // mp3
    private var _recordingMp3 = false
    private var cAmplitude = 0
    private var _mp3buffer: ByteArray? = null
    private var androidLame: AndroidLame? = null
    private var outputStream: FileOutputStream? = null
    private var audioRecorder: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var encodeRunnable: Runnable? = null

    private var mediaRecorder: MediaRecorder? = null
    private var mediaPlayer: MediaPlayer? = null
    private var recorderRunnable: Runnable? = null
    private var mTask: TimerTask? = null
    private var mTimer: Timer? = null
    private var pausedRecordTime = 0L
    private var totalPausedRecordTime = 0L
    var recordHandler: Handler? = Handler(Looper.getMainLooper())

    override fun getName(): String {
        return tag
    }

    private fun checkRecorderPermissions(promise: Promise): Boolean {
        try {
            if ((ActivityCompat.checkSelfPermission(reactContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
                            ActivityCompat.checkSelfPermission(reactContext, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED)) {
                ActivityCompat.requestPermissions((currentActivity)!!, arrayOf(
                        Manifest.permission.RECORD_AUDIO,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE), 0)
                promise.reject("No permission granted.", "Try again after adding permission.")
                return false
            }
        } catch (ne: NullPointerException) {
            Log.w(tag, ne.toString())
            promise.reject("No permission granted.", "Try again after adding permission.")
            return false
        }

        return true
    }

    private fun getRawAmplitude(bufferReadSize: Int, buffer: ShortArray): Int {
        if (bufferReadSize < 0) {
            return 0
        }

        var sum = 0
        for (i in 0..bufferReadSize) {
            sum += abs(buffer[i].toInt())
        }

        if (bufferReadSize > 0) {
            return sum / bufferReadSize
        }

        return 0
    }

    private fun recordProgress() {
        val systemTime = SystemClock.elapsedRealtime()
        recorderRunnable = object : Runnable {
            override fun run() {
                val time = SystemClock.elapsedRealtime() - systemTime - totalPausedRecordTime
                val obj = Arguments.createMap()
                obj.putDouble("currentPosition", time.toDouble())
                if (_meteringEnabled) {
                    var maxAmplitude = 0
                    if (mediaRecorder != null) {
                        maxAmplitude = mediaRecorder!!.maxAmplitude
                    }
                    if (audioRecorder != null && _mp3buffer != null) {
                        maxAmplitude = cAmplitude
                    }
                    var dB = -160.0
                    val maxAudioSize = 32768.0
                    if (maxAmplitude > 0) {
                        dB = 20 * log10(maxAmplitude / maxAudioSize)
                    }
                    obj.putInt("currentMetering", dB.toInt())
                }
                sendEvent(reactContext, "rn-recordback", obj)
                recordHandler!!.postDelayed(this, subsDurationMillis.toLong())
            }
        }
        (recorderRunnable as Runnable).run()
    }

    private fun record(path: String, audioSet: ReadableMap?) {
        audioFileURL = if (((path == "DEFAULT"))) "${reactContext.cacheDir}/$defaultFileName" else "${reactContext.cacheDir}/$path"
        if (mediaRecorder == null) {
            mediaRecorder = MediaRecorder()
        }

        if (audioSet != null) {
            mediaRecorder!!.setAudioSource(if (audioSet.hasKey("AudioSourceAndroid")) audioSet.getInt("AudioSourceAndroid") else MediaRecorder.AudioSource.MIC)
            mediaRecorder!!.setOutputFormat(if (audioSet.hasKey("OutputFormatAndroid")) audioSet.getInt("OutputFormatAndroid") else MediaRecorder.OutputFormat.MPEG_4)
            mediaRecorder!!.setAudioEncoder(if (audioSet.hasKey("AudioEncoderAndroid")) audioSet.getInt("AudioEncoderAndroid") else MediaRecorder.AudioEncoder.AAC)
            mediaRecorder!!.setAudioSamplingRate(if (audioSet.hasKey("AudioSamplingRateAndroid")) audioSet.getInt("AudioSamplingRateAndroid") else 48000)
            mediaRecorder!!.setAudioEncodingBitRate(if (audioSet.hasKey("AudioEncodingBitRateAndroid")) audioSet.getInt("AudioEncodingBitRateAndroid") else 128000)
        } else {
            mediaRecorder!!.setAudioSource(MediaRecorder.AudioSource.MIC)
            mediaRecorder!!.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            mediaRecorder!!.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            mediaRecorder!!.setAudioEncodingBitRate(128000)
            mediaRecorder!!.setAudioSamplingRate(48000)
        }
        mediaRecorder!!.setOutputFile(audioFileURL)
        mediaRecorder!!.prepare()
        mediaRecorder!!.start()
    }

    @SuppressLint("MissingPermission")
    private fun recordMp3(path: String, audioSet: ReadableMap?) {
        audioFileURL = if (((path == "DEFAULT"))) "${reactContext.cacheDir}/$defaultMp3FileName" else "${reactContext.cacheDir}/$path"
        _recordingMp3 = true

        var inSampleRate = 44100
        var source = MediaRecorder.AudioSource.MIC
        if (audioSet != null && audioSet.hasKey("AudioSamplingRateAndroid")) {
            inSampleRate = if (audioSet.hasKey("AudioSamplingRateAndroid")) audioSet.getInt("AudioSamplingRateAndroid") else 44100
            source = if (audioSet.hasKey("AudioSourceAndroid")) audioSet.getInt("AudioSourceAndroid") else MediaRecorder.AudioSource.MIC
        }
        val minBuffer = AudioRecord.getMinBufferSize(inSampleRate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT)


        if (audioRecorder == null) {
            audioRecorder = AudioRecord(source, inSampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, minBuffer * 2)
        }


        //create a file output stream for the path at which  the mp3 file should be written.
        val bufferSize = inSampleRate * 2 * 5
        val buffer = ShortArray(bufferSize)

        _mp3buffer = ByteArray(bufferSize)
        outputStream = FileOutputStream(File(audioFileURL))

        androidLame = LameBuilder()
                .setInSampleRate(inSampleRate)
                .setOutChannels(1)
                .setOutBitrate(32)
                .setOutSampleRate(inSampleRate)
                .build()

        // now start the recording
        audioRecorder?.startRecording()

        encodeRunnable = Runnable {
            while (_recordingMp3) {
                val bytesRead = audioRecorder!!.read(buffer, 0, minBuffer)
                if (bytesRead > 0) {
                    val bytesEncoded: Int = androidLame!!.encode(buffer, buffer, bytesRead, _mp3buffer)
                    if (bytesEncoded > 0) {
                        try {
                            outputStream?.write(_mp3buffer, 0, bytesEncoded)
                        } catch (e: IOException) {
                            e.printStackTrace()
                        }
                    }
                }

                if (_meteringEnabled) {
                    cAmplitude = getRawAmplitude(bytesRead, buffer)
                }
            }
        }

        recordingThread = Thread(encodeRunnable, "Mp3 Thread")
        recordingThread!!.start()
    }

    @ReactMethod
    fun startRecorder(path: String, audioSet: ReadableMap?, meteringEnabled: Boolean, promise: Promise) {
        if (!checkRecorderPermissions(promise)) {
            return
        }

        try {
            // Is mp3?
            var isMp3 = false
            if (audioSet != null) {
                isMp3 = audioSet.hasKey("OutputFormatAndroid") && audioSet.getInt("OutputFormatAndroid") == 300
            }

            _meteringEnabled = meteringEnabled
            totalPausedRecordTime = 0L

            if (isMp3) {
                recordMp3(path, audioSet)
            } else {
                record(path, audioSet)
            }
            recordProgress()
            promise.resolve("file:///$audioFileURL")
        } catch (e: Exception) {
            Log.e(tag, "Exception: ", e)
            promise.reject("startRecord", e.message)
        }
    }

    @ReactMethod
    fun resumeRecorder(promise: Promise) {
        if (mediaRecorder == null) {
            promise.reject("resumeRecorder", "Recorder is null.")
            return
        }

        try {
            mediaRecorder!!.resume()
            totalPausedRecordTime += SystemClock.elapsedRealtime() - pausedRecordTime
            recorderRunnable?.let { recordHandler!!.postDelayed(it, subsDurationMillis.toLong()) }
            promise.resolve("Recorder resumed.")
        } catch (e: Exception) {
            Log.e(tag, "Recorder resume: " + e.message)
            promise.reject("resumeRecorder", e.message)
        }
    }

    @ReactMethod
    fun pauseRecorder(promise: Promise) {
        if (mediaRecorder == null) {
            promise.reject("pauseRecorder", "Recorder is null.")
            return
        }

        try {
            mediaRecorder!!.pause()
            pausedRecordTime = SystemClock.elapsedRealtime()
            recorderRunnable?.let { recordHandler!!.removeCallbacks(it) }
            promise.resolve("Recorder paused.")
        } catch (e: Exception) {
            Log.e(tag, "pauseRecorder exception: " + e.message)
            promise.reject("pauseRecorder", e.message)
        }
    }

    @ReactMethod
    fun stopRecorder(promise: Promise) {
        _recordingMp3 = false
        cAmplitude = 0
        if (recordHandler != null) {
            recorderRunnable?.let { recordHandler!!.removeCallbacks(it) }
        }

        if (mediaRecorder == null && audioRecorder == null ) {
            promise.reject("stopRecord", "recorder is null.")
            return
        }

        try {
            mediaRecorder?.stop()
            audioRecorder?.stop()
            recordingThread = null

            //now flush
            if (_mp3buffer != null && androidLame != null) {
                val outputMp3buf: Int = androidLame!!.flush(_mp3buffer)

                if (outputMp3buf > 0 && outputStream != null) {
                    outputStream!!.write(_mp3buffer, 0, outputMp3buf)
                    outputStream!!.close()
                }
            }
        } catch (stopException: Exception) {
            stopException.message?.let { Log.d(tag,"" + it) }
            promise.reject("stopRecord", stopException.message)
        }

        mediaRecorder?.release()
        audioRecorder?.release()
        audioRecorder = null
        mediaRecorder = null
        _mp3buffer = null
        promise.resolve("file:///$audioFileURL")
    }

    @ReactMethod
    fun setVolume(volume: Double, promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("setVolume", "player is null.")
            return
        }

        val mVolume = volume.toFloat()
        mediaPlayer!!.setVolume(mVolume, mVolume)
        promise.resolve("set volume")
    }

    @ReactMethod
    fun startPlayer(path: String, httpHeaders: ReadableMap?, promise: Promise) {
        if (mediaPlayer != null) {
            val isPaused = !mediaPlayer!!.isPlaying && mediaPlayer!!.currentPosition > 1

            if (isPaused) {
                mediaPlayer!!.start()
                promise.resolve("player resumed.")
                return
            }

            Log.e(tag, "Player is already running. Stop it first.")
            promise.reject("startPlay", "Player is already running. Stop it first.")
            return
        } else {
            mediaPlayer = MediaPlayer()
        }

        try {
            if ((path == "DEFAULT")) {
                var fileName = "${reactContext.cacheDir}/$defaultMp3FileName"
                if (!File(fileName).exists()) {
                    fileName = "${reactContext.cacheDir}/$defaultFileName"
                }
                mediaPlayer!!.setDataSource(fileName)
            } else {
                if (httpHeaders != null) {
                    val headers: MutableMap<String, String?> = HashMap<String, String?>()
                    val iterator = httpHeaders.keySetIterator()
                    while (iterator.hasNextKey()) {
                        val key = iterator.nextKey()
                        headers[key] = httpHeaders.getString(key)
                    }
                    mediaPlayer!!.setDataSource(currentActivity!!.applicationContext, Uri.parse(path), headers)
                } else {
                    mediaPlayer!!.setDataSource("${reactContext.cacheDir}/$path")
                }
            }

            mediaPlayer!!.setOnPreparedListener { mp ->
                Log.d(tag, "mediaPlayer prepared and start")
                mp.start()
                /**
                 * Set timer task to send event to RN.
                 */
                mTask = object : TimerTask() {
                    override fun run() {
                        val obj = Arguments.createMap()
                        obj.putInt("duration", mp.duration)
                        obj.putInt("currentPosition", mp.currentPosition)
                        sendEvent(reactContext, "rn-playback", obj)
                    }
                }

                mTimer = Timer()
                mTimer!!.schedule(mTask, 0, subsDurationMillis.toLong())
                val resolvedPath = if (((path == "DEFAULT"))) "${reactContext.cacheDir}/$defaultFileName" else "${reactContext.cacheDir}/$path"
                promise.resolve(resolvedPath)
            }

            /**
             * Detect when finish playing.
             */
            mediaPlayer!!.setOnCompletionListener { mp ->
                /**
                 * Send last event
                 */
                val obj = Arguments.createMap()
                obj.putInt("duration", mp.duration)
                obj.putInt("currentPosition", mp.duration)
                sendEvent(reactContext, "rn-playback", obj)
                /**
                 * Reset player.
                 */
                Log.d(tag, "Plays completed.")
                mTimer!!.cancel()
                mp.stop()
                mp.release()
                mediaPlayer = null
            }

            mediaPlayer!!.prepare()
        } catch (e: IOException) {
            Log.e(tag, "startPlay() io exception")
            promise.reject("startPlay", e.message)
        } catch (e: NullPointerException) {
            Log.e(tag, "startPlay() null exception")
        }
    }

    @ReactMethod
    fun resumePlayer(promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("resume", "mediaPlayer is null on resume.")
            return
        }

        if (mediaPlayer!!.isPlaying) {
            promise.reject("resume", "mediaPlayer is already running.")
            return
        }

        try {
            mediaPlayer!!.seekTo(mediaPlayer!!.currentPosition)
            mediaPlayer!!.start()
            promise.resolve("resume player")
        } catch (e: Exception) {
            Log.e(tag, "mediaPlayer resume: " + e.message)
            promise.reject("resume", e.message)
        }
    }

    @ReactMethod
    fun pausePlayer(promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("pausePlay", "mediaPlayer is null on pause.")
            return
        }

        try {
            mediaPlayer!!.pause()
            promise.resolve("pause player")
        } catch (e: Exception) {
            Log.e(tag, "pausePlay exception: " + e.message)
            promise.reject("pausePlay", e.message)
        }
    }

    @ReactMethod
    fun seekToPlayer(time: Double, promise: Promise) {
        if (mediaPlayer == null) {
            promise.reject("seekTo", "mediaPlayer is null on seek.")
            return
        }

        mediaPlayer!!.seekTo(time.toInt())
        promise.resolve("pause player")
    }

    private fun sendEvent(reactContext: ReactContext,
                          eventName: String,
                          params: WritableMap?) {
        reactContext
                .getJSModule(RCTDeviceEventEmitter::class.java)
                .emit(eventName, params)
    }

    @ReactMethod
    fun stopPlayer(promise: Promise) {
        if (mTimer != null) {
            mTimer!!.cancel()
        }

        if (mediaPlayer == null) {
            promise.resolve("Already stopped player")
            return
        }

        try {
            mediaPlayer!!.release()
            mediaPlayer = null
            promise.resolve("stopped player")
        } catch (e: Exception) {
            Log.e(tag, "stopPlay exception: " + e.message)
            promise.reject("stopPlay", e.message)
        }
    }

    @ReactMethod
    fun setSubscriptionDuration(sec: Double, promise: Promise) {
        subsDurationMillis = (sec * 1000).toInt()
        promise.resolve("setSubscriptionDuration: $subsDurationMillis")
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean {
        val requestRecordAudioPermission = 200

        when (requestCode) {
            requestRecordAudioPermission -> if (grantResults[0] == PackageManager.PERMISSION_GRANTED) return true
        }

        return false
    }

    companion object {
        private var tag = "RNAudioRecorderPlayer"
        private var defaultFileName = "sound.mp4"
        private var defaultMp3FileName = "sound.mp3"
    }
}
