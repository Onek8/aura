// =============================================================================
// audioCallback() and getSampleCache() are roughly based on
// https://github.com/Kode/Kha/blob/master/Sources/kha/audio2/Audio1.hx
//
// References:
// [1]: https://github.com/Kode/Kha/blob/3a3e9e6d51b1d6e3309a80cd795860da3ea07355/Backends/Kinc-hxcpp/main.cpp#L186-L233
//
// =============================================================================

package aura;

import haxe.ds.Vector;

import kha.Assets;
import kha.SystemImpl;
import kha.arrays.Float32Array;
import kha.audio2.Audio1;

import aura.MixChannelHandle;
import aura.channels.Html5StreamChannel;
import aura.channels.MixChannel;
import aura.channels.ResamplingAudioChannel;
import aura.channels.StreamChannel;
import aura.utils.Assert;
import aura.utils.BufferUtils.clearBuffer;
import aura.utils.MathUtils;

@:access(aura.MixChannelHandle)
class Aura {
	public static var sampleRate(default, null): Int;

	public static var listener: Listener;

	public static final mixChannels = new Map<String, MixChannelHandle>();
	public static var masterChannel(default, null): MixChannelHandle;

	static var sampleCaches: Vector<kha.arrays.Float32Array>;

	/**
		Number of audioCallback() invocations since the last allocation. This is
		used to automatically switch off interactions with the garbage collector
		in the audio thread if there are no allocations for some time (for extra
		performance).
	**/
	static var lastAllocationTimer: Int = 0;

	public static function init(channelSize: Int = 16) {
		sampleRate = kha.audio2.Audio.samplesPerSecond;
		assert(Critical, sampleRate != 0, "sampleRate must not be 0!");

		@:privateAccess MixChannel.channelSize = channelSize;

		listener = new Listener();

		// Create a few preconfigured mix channels
		masterChannel = createMixChannel("master");
		masterChannel.addInputChannel(createMixChannel("music"));
		masterChannel.addInputChannel(createMixChannel("fx"));

		// TODO: Make max tree height configurable
		sampleCaches = new Vector(8);

		kha.audio2.Audio.audioCallback = audioCallback;
	}

	public static function loadSounds(sounds: AuraLoadConfig, done: Void->Void, ?failed: Void->Void) {
		final length = sounds.compressed.length + sounds.uncompressed.length;
		var count = 0;

		for (soundName in sounds.compressed) {
			if (!doesSoundExist(soundName)) {
				onLoadingError(null, failed, soundName);
				break;
			}
			Assets.loadSound(soundName, (sound: kha.Sound) -> {
				#if !kha_krom // Krom only uses uncompressedData
				if (sound.compressedData == null) {
					throw 'Cannot compress already uncompressed sound ${soundName}!';
				}
				#end

				if (++count == length) {
					done();
					return;
				}
			}, (error: kha.AssetError) -> { onLoadingError(error, failed, soundName); });
		}

		for (soundName in sounds.uncompressed) {
			if (!doesSoundExist(soundName)) {
				onLoadingError(null, failed, soundName);
				break;
			}
			Assets.loadSound(soundName, (sound: kha.Sound) -> {
				if (sound.uncompressedData == null) {
					sound.uncompress(() -> {
						if (++count == length) {
							done();
							return;
						}
					});
				}
				else {
					if (++count == length) {
						done();
						return;
					}
				}
			}, (error: kha.AssetError) -> { onLoadingError(error, failed, soundName); });
		}
	}

	static function onLoadingError(error: Null<kha.AssetError>, failed: Null<Void->Void>, soundName: String) {
		final errorInfo = error == null ? "" : "\nOriginal error: " + error.url + "..." + error.error;

		trace(
			'Could not load sound "$soundName", make sure that all sounds are named\n'
			+ "  correctly and that they are included in the khafile.js."
			+ errorInfo
		);

		if (failed != null) {
			failed();
		}
	}

	/**
		Returns whether a sound exists and can be loaded.
	**/
	public static inline function doesSoundExist(soundName: String): Bool {
		// Use reflection instead of Asset.sounds.get() to prevent errors on
		// static targets. A sound's description is the sound's entry in
		// files.json and not a kha.Sound, but get() returns a sound which would
		// lead to a invalid cast exception.

		// Relying on Kha internals ("Description" as name) is bad, but there is
		// no good alternative...
		return Reflect.field(Assets.sounds, soundName + "Description") != null;
	}

	public static inline function getSound(soundName: String): Null<kha.Sound> {
		return Assets.sounds.get(soundName);
	}

	public static function play(sound: kha.Sound, loop: Bool = false, mixChannelHandle: Null<MixChannelHandle> = null): Null<Handle> {
		if (mixChannelHandle == null) {
			mixChannelHandle = masterChannel;
		}

		assert(Critical, sound.uncompressedData != null);

		// TODO: Like Kha, only use resampling channel if pitch is used or if samplerate of sound and system differs
		final channel = new ResamplingAudioChannel(loop, sound.sampleRate);
		@:privateAccess channel.data = sound.uncompressedData;

		final handle = new Handle(channel);
		final foundChannel = mixChannelHandle.addInputChannel(handle);

		return foundChannel ? handle : null;
	}

	public static function stream(sound: kha.Sound, loop: Bool = false, mixChannelHandle: Null<MixChannelHandle> = null): Null<Handle> {
		#if kha_krom // Krom only uses uncompressedData -> no streaming
		return play(sound, loop, mixChannelHandle);
		#else

		if (mixChannelHandle == null) {
			mixChannelHandle = masterChannel;
		}

		assert(Critical, sound.compressedData != null);

		final khaChannel: Null<kha.audio1.AudioChannel> = kha.audio2.Audio1.stream(sound, loop);

		if (khaChannel == null) {
			return null;
		}

		#if (kha_html5 || kha_debug_html5)
		final auraChannel = SystemImpl.mobileAudioPlaying ? new Html5StreamChannel(cast khaChannel) : new StreamChannel(cast khaChannel);
		#else
		final auraChannel = new StreamChannel(cast khaChannel);
		#end

		final handle = new Handle(auraChannel);
		final foundChannel = mixChannelHandle.addInputChannel(handle);

		return foundChannel ? handle : null;
		#end
	}

	/**
		Create a `MixChannel` to control a group of other channels together.
		@param name Optional name. If not empty, the name can be used later to
			retrieve the channel handle via `Aura.mixChannels[name]`.
	**/
	public static inline function createMixChannel(name: String = ""): MixChannelHandle {
		final handle = new MixChannelHandle(new MixChannel());
		if (name != "") {
			assert(Error, !mixChannels.exists(name), 'MixChannel with name $name already exists!');
			mixChannels[name] = handle;
		}
		return handle;
	}

	public static function getSampleCache(treeLevel: Int, length: Int): Null<Float32Array> {
		var cache = sampleCaches[treeLevel];

		if (cache == null || cache.length < length) {
			if (kha.audio2.Audio.disableGcInteractions) {
				// This code is executed in the case that there are suddenly
				// more samples requested while the GC interactions are turned
				// off (because the number of samples was sufficient for a
				// longer time). We can't just turn on GC interactions, it will
				// not take effect before the next audio callback invocation, so
				// we skip this "frame" instead (see [1] for reference).

				trace("Unexpected allocation request in audio thread.");
				final haveMsg = (cache == null) ? 'no cache' : '${cache.length}';
				trace('  treeLevel: $treeLevel, wanted length: $length (have: $haveMsg)');

				lastAllocationTimer = 0;
				kha.audio2.Audio.disableGcInteractions = false;
				return null;
			}

			// If the cache exists but is too small, overallocate by factor 2 to
			// avoid too many allocations, eventually the cache will be big
			// enough for the required amount of samples. If the cache does not
			// exist yet, do not overallocate to prevent too high memory usage
			// (the requested length should not change much).
			sampleCaches[treeLevel] = cache = new Float32Array(cache == null ? length : length * 2);
			lastAllocationTimer = 0;
		}
		else if (treeLevel == 0) {
			if (lastAllocationTimer > 100) {
				kha.audio2.Audio.disableGcInteractions = true;
			}
			else {
				lastAllocationTimer += 1;
			}
		}

		return cache;
	}

	/**
		Mixes all sub channels and sounds in this channel together.

		Based on `kha.audio2.Audio1.mix()`.

		@param samplesBox Wrapper that holds the amount of requested samples.
		@param buffer The buffer into which to write the output samples.
	**/
	static function audioCallback(samplesBox: kha.internal.IntBox, buffer: kha.audio2.Buffer): Void {
		Time.update();

		final samples = samplesBox.value;
		final sampleCache = getSampleCache(0, samples);

		if (sampleCache == null) {
			for (i in 0...samples) {
				buffer.data.set(buffer.writeLocation, 0);
				buffer.writeLocation += 1;
				if (buffer.writeLocation >= buffer.size) {
					buffer.writeLocation = 0;
				}
			}
			return;
		}

		// Copy reference to masterChannel for some more thread safety.
		// TODO: Investigate if other solutions are required here
		var master: MixChannel = masterChannel.getMixChannel();
		master.synchronize();

		clearBuffer(sampleCache, samples);

		if (master != null) {
			master.nextSamples(sampleCache, samples, buffer.samplesPerSecond);
		}

		for (i in 0...samples) {
			// Write clamped samples to final buffer
			buffer.data.set(buffer.writeLocation, maxF(minF(sampleCache[i], 1.0), -1.0));
			buffer.writeLocation += 1;
			if (buffer.writeLocation >= buffer.size) {
				buffer.writeLocation = 0;
			}
		}
	}
}

@:structInit
class AuraLoadConfig {
	public final compressed: Array<String> = [];
	public final uncompressed: Array<String> = [];
}
