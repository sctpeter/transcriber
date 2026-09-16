import CSherpaOnnx

/// swift-api-examples/SherpaOnnx.swift
/// Copyright (c)  2023  Xiaomi Corporation
///
/// Licensed under the Apache License, Version 2.0 (see LICENSES/Apache-2.0.txt).
/// Modified for Transcriber: added `import CSherpaOnnx`; removed upstream APIs after
/// line 1014 of sherpa-onnx v1.13.3 (TTS etc., unused here). See THIRD_PARTY_NOTICES.md.

import Foundation  // For NSString

/// Convert a String from swift to a `const char*` so that we can pass it to
/// the C language.
///
/// - Parameters:
///   - s: The String to convert.
/// - Returns: A pointer that can be passed to C as `const char*`

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

/// Return an instance of SherpaOnnxOnlineTransducerModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - encoder: Path to encoder.onnx
///   - decoder: Path to decoder.onnx
///   - joiner: Path to joiner.onnx
///
/// - Returns: Return an instance of SherpaOnnxOnlineTransducerModelConfig
func sherpaOnnxOnlineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOnlineTransducerModelConfig {
  return SherpaOnnxOnlineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

/// Return an instance of SherpaOnnxOnlineParaformerModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - encoder: Path to encoder.onnx
///   - decoder: Path to decoder.onnx
///
/// - Returns: Return an instance of SherpaOnnxOnlineParaformerModelConfig
func sherpaOnnxOnlineParaformerModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOnlineParaformerModelConfig {
  return SherpaOnnxOnlineParaformerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

func sherpaOnnxOnlineZipformer2CtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineZipformer2CtcModelConfig {
  return SherpaOnnxOnlineZipformer2CtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOnlineNemoCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineNemoCtcModelConfig {
  return SherpaOnnxOnlineNemoCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOnlineToneCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOnlineToneCtcModelConfig {
  return SherpaOnnxOnlineToneCtcModelConfig(
    model: toCPointer(model)
  )
}

/// Return an instance of SherpaOnnxOnlineModelConfig.
///
/// Please refer to
/// https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html
/// to download the required `.onnx` files.
///
/// - Parameters:
///   - tokens: Path to tokens.txt
///   - numThreads:  Number of threads to use for neural network computation.
///
/// - Returns: Return an instance of SherpaOnnxOnlineTransducerModelConfig
func sherpaOnnxOnlineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOnlineTransducerModelConfig = sherpaOnnxOnlineTransducerModelConfig(),
  paraformer: SherpaOnnxOnlineParaformerModelConfig = sherpaOnnxOnlineParaformerModelConfig(),
  zipformer2Ctc: SherpaOnnxOnlineZipformer2CtcModelConfig =
    sherpaOnnxOnlineZipformer2CtcModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  tokensBuf: String = "",
  tokensBufSize: Int = 0,
  nemoCtc: SherpaOnnxOnlineNemoCtcModelConfig = sherpaOnnxOnlineNemoCtcModelConfig(),
  toneCtc: SherpaOnnxOnlineToneCtcModelConfig = sherpaOnnxOnlineToneCtcModelConfig()
) -> SherpaOnnxOnlineModelConfig {
  return SherpaOnnxOnlineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    zipformer2_ctc: zipformer2Ctc,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    tokens_buf: toCPointer(tokensBuf),
    tokens_buf_size: Int32(tokensBufSize),
    nemo_ctc: nemoCtc,
    t_one_ctc: toneCtc
  )
}

func sherpaOnnxFeatureConfig(
  sampleRate: Int = 16000,
  featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
  return SherpaOnnxFeatureConfig(
    sample_rate: Int32(sampleRate),
    feature_dim: Int32(featureDim))
}

func sherpaOnnxOnlineCtcFstDecoderConfig(
  graph: String = "",
  maxActive: Int = 3000
) -> SherpaOnnxOnlineCtcFstDecoderConfig {
  return SherpaOnnxOnlineCtcFstDecoderConfig(
    graph: toCPointer(graph),
    max_active: Int32(maxActive))
}

func sherpaOnnxHomophoneReplacerConfig(
  dictDir: String = "",
  lexicon: String = "",
  ruleFsts: String = ""
) -> SherpaOnnxHomophoneReplacerConfig {
  return SherpaOnnxHomophoneReplacerConfig(
    dict_dir: toCPointer(dictDir),
    lexicon: toCPointer(lexicon),
    rule_fsts: toCPointer(ruleFsts))
}

func sherpaOnnxOnlineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOnlineModelConfig,
  enableEndpoint: Bool = false,
  rule1MinTrailingSilence: Float = 2.4,
  rule2MinTrailingSilence: Float = 1.2,
  rule3MinUtteranceLength: Float = 30,
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ctcFstDecoderConfig: SherpaOnnxOnlineCtcFstDecoderConfig = sherpaOnnxOnlineCtcFstDecoderConfig(),
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hotwordsBuf: String = "",
  hotwordsBufSize: Int = 0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOnlineRecognizerConfig {
  return SherpaOnnxOnlineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    enable_endpoint: enableEndpoint ? 1 : 0,
    rule1_min_trailing_silence: rule1MinTrailingSilence,
    rule2_min_trailing_silence: rule2MinTrailingSilence,
    rule3_min_utterance_length: rule3MinUtteranceLength,
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    ctc_fst_decoder_config: ctcFstDecoderConfig,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hotwords_buf: toCPointer(hotwordsBuf),
    hotwords_buf_size: Int32(hotwordsBufSize),
    hr: hr
  )
}

/// Wrapper for recognition result.
///
/// Usage:
///
///  let result = recognizer.getResult()
///  print("text: \(result.text)")
///
class SherpaOnnxOnlineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  private let result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _tokens: [String] = {
    guard let tokensPointer = result.pointee.tokens_arr else { return [] }
    return (0..<count).compactMap { index in
      guard let ptr = tokensPointer[index] else { return nil }
      return String(cString: ptr)
    }
  }()

  private lazy var _timestamps: [Float] = {
    guard let timestampsPointer = result.pointee.timestamps else { return [] }
    return (0..<count).map { index in timestampsPointer[index] }
  }()

  init(result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOnlineRecognizerResult(result)
  }

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  var text: String { _text }

  var count: Int { Int(result.pointee.count) }

  var tokens: [String] { _tokens }

  var timestamps: [Float] { _timestamps }
}

class SherpaOnnxRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer
  private var stream: OpaquePointer
  private let lock = NSLock()  // for thread-safe stream replacement

  /// Constructor taking a model config
  init(
    config: UnsafePointer<SherpaOnnxOnlineRecognizerConfig>
  ) {
    self.recognizer = SherpaOnnxCreateOnlineRecognizer(config)
    self.stream = SherpaOnnxCreateOnlineStream(recognizer)
  }

  deinit {
    SherpaOnnxDestroyOnlineStream(stream)
    SherpaOnnxDestroyOnlineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  func acceptWaveform(samples: [Float], sampleRate: Int = 16_000) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
  }

  func isReady() -> Bool {
    return SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0
  }

  /// If there are enough number of feature frames, it invokes the neural
  /// network computation and decoding. Otherwise, it is a no-op.
  func decode() {
    SherpaOnnxDecodeOnlineStream(recognizer, stream)
  }

  /// Get the decoding results so far
  func getResult() -> SherpaOnnxOnlineRecongitionResult {
    guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
      fatalError("SherpaOnnxGetOnlineStreamResult returned nil")
    }
    return SherpaOnnxOnlineRecongitionResult(result: result)
  }

  /// Reset the recognizer, which clears the neural network model state
  /// and the state for decoding.
  /// If hotwords is an empty string, it just recreates the decoding stream
  /// If hotwords is not empty, it will create a new decoding stream with
  /// the given hotWords appended to the default hotwords.
  func reset(hotwords: String? = nil) {
    guard let words = hotwords, !words.isEmpty else {
      SherpaOnnxOnlineStreamReset(recognizer, stream)
      return
    }

    words.withCString { cString in
      guard let newStream = SherpaOnnxCreateOnlineStreamWithHotwords(recognizer, cString) else {
        fatalError("SherpaOnnxCreateOnlineStreamWithHotwords returned nil")
      }
      lock.lock()
      // lock while release and replace stream
      SherpaOnnxDestroyOnlineStream(stream)
      stream = newStream
      lock.unlock()
    }
  }

  /// Signal that no more audio samples would be available.
  /// After this call, you cannot call acceptWaveform() any more.
  func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(stream)
  }

  /// Return true is an endpoint has been detected.
  func isEndpoint() -> Bool {
    return SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0
  }
}

// For offline APIs

func sherpaOnnxOfflineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
  return SherpaOnnxOfflineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

func sherpaOnnxOfflineParaformerModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineParaformerModelConfig {
  return SherpaOnnxOfflineParaformerModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineZipformerCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineZipformerCtcModelConfig {
  return SherpaOnnxOfflineZipformerCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWenetCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineWenetCtcModelConfig {
  return SherpaOnnxOfflineWenetCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
  return SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineMedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineMedAsrCtcModelConfig {
  return SherpaOnnxOfflineMedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineFireRedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineFireRedAsrCtcModelConfig {
  return SherpaOnnxOfflineFireRedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineNemoEncDecCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
  return SherpaOnnxOfflineNemoEncDecCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineDolphinModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineDolphinModelConfig {
  return SherpaOnnxOfflineDolphinModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWhisperModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  task: String = "transcribe",
  tailPaddings: Int = -1,
  enableTokenTimestamps: Bool = false,
  enableSegmentTimestamps: Bool = false
) -> SherpaOnnxOfflineWhisperModelConfig {
  return SherpaOnnxOfflineWhisperModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    task: toCPointer(task),
    tail_paddings: Int32(tailPaddings),
    enable_token_timestamps: enableTokenTimestamps ? 1 : 0,
    enable_segment_timestamps: enableSegmentTimestamps ? 1 : 0
  )
}

func sherpaOnnxOfflineCanaryModelConfig(
  encoder: String = "",
  decoder: String = "",
  srcLang: String = "en",
  tgtLang: String = "en",
  usePnc: Bool = true
) -> SherpaOnnxOfflineCanaryModelConfig {
  return SherpaOnnxOfflineCanaryModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    src_lang: toCPointer(srcLang),
    tgt_lang: toCPointer(tgtLang),
    use_pnc: usePnc ? 1 : 0
  )
}

func sherpaOnnxOfflineCohereTranscribeModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  usePunct: Bool = true,
  useInverseTextNormalization: Bool = true
) -> SherpaOnnxOfflineCohereTranscribeModelConfig {
  return SherpaOnnxOfflineCohereTranscribeModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    use_punct: usePunct ? 1 : 0,
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineFireRedAsrModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOfflineFireRedAsrModelConfig {
  return SherpaOnnxOfflineFireRedAsrModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

// there are two versions of Moonshine
// For v1, you need four models: preprocessor, encoder, uncachedDecoder, cachedDecoder
// For v2, you need two models: encoder, mergedDecoder
func sherpaOnnxOfflineMoonshineModelConfig(
  preprocessor: String = "",
  encoder: String = "",
  uncachedDecoder: String = "",
  cachedDecoder: String = "",
  mergedDecoder: String = ""
) -> SherpaOnnxOfflineMoonshineModelConfig {
  return SherpaOnnxOfflineMoonshineModelConfig(
    preprocessor: toCPointer(preprocessor),
    encoder: toCPointer(encoder),
    uncached_decoder: toCPointer(uncachedDecoder),
    cached_decoder: toCPointer(cachedDecoder),
    merged_decoder: toCPointer(mergedDecoder)
  )
}

func sherpaOnnxOfflineQwen3ASRModelConfig(
  convFrontend: String = "",
  encoder: String = "",
  decoder: String = "",
  tokenizer: String = "",
  maxTotalLen: Int = 512,
  maxNewTokens: Int = 128,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  hotwords: String = ""
) -> SherpaOnnxOfflineQwen3ASRModelConfig {
  return SherpaOnnxOfflineQwen3ASRModelConfig(
    conv_frontend: toCPointer(convFrontend),
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    tokenizer: toCPointer(tokenizer),
    max_total_len: Int32(maxTotalLen),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineTdnnModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineTdnnModelConfig {
  return SherpaOnnxOfflineTdnnModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineSenseVoiceModelConfig(
  model: String = "",
  language: String = "",
  useInverseTextNormalization: Bool = false
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
  return SherpaOnnxOfflineSenseVoiceModelConfig(
    model: toCPointer(model),
    language: toCPointer(language),
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineLMConfig(
  model: String = "",
  scale: Float = 1.0
) -> SherpaOnnxOfflineLMConfig {
  return SherpaOnnxOfflineLMConfig(
    model: toCPointer(model),
    scale: scale
  )
}

func sherpaOnnxOfflineFunASRNanoModelConfig(
  encoderAdaptor: String = "",
  llm: String = "",
  embedding: String = "",
  tokenizer: String = "",
  systemPrompt: String = "You are a helpful assistant.",
  userPrompt: String = "语音转写：",
  maxNewTokens: Int = 512,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  language: String = "",
  itn: Bool = true,
  hotwords: String = ""
) -> SherpaOnnxOfflineFunASRNanoModelConfig {
  return SherpaOnnxOfflineFunASRNanoModelConfig(
    encoder_adaptor: toCPointer(encoderAdaptor),
    llm: toCPointer(llm),
    embedding: toCPointer(embedding),
    tokenizer: toCPointer(tokenizer),
    system_prompt: toCPointer(systemPrompt),
    user_prompt: toCPointer(userPrompt),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    language: toCPointer(language),
    itn: itn ? 1 : 0,
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
  paraformer: SherpaOnnxOfflineParaformerModelConfig = sherpaOnnxOfflineParaformerModelConfig(),
  nemoCtc: SherpaOnnxOfflineNemoEncDecCtcModelConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
  whisper: SherpaOnnxOfflineWhisperModelConfig = sherpaOnnxOfflineWhisperModelConfig(),
  tdnn: SherpaOnnxOfflineTdnnModelConfig = sherpaOnnxOfflineTdnnModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  teleSpeechCtc: String = "",
  senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig = sherpaOnnxOfflineSenseVoiceModelConfig(),
  moonshine: SherpaOnnxOfflineMoonshineModelConfig = sherpaOnnxOfflineMoonshineModelConfig(),
  fireRedAsr: SherpaOnnxOfflineFireRedAsrModelConfig = sherpaOnnxOfflineFireRedAsrModelConfig(),
  dolphin: SherpaOnnxOfflineDolphinModelConfig = sherpaOnnxOfflineDolphinModelConfig(),
  zipformerCtc: SherpaOnnxOfflineZipformerCtcModelConfig =
    sherpaOnnxOfflineZipformerCtcModelConfig(),
  canary: SherpaOnnxOfflineCanaryModelConfig = sherpaOnnxOfflineCanaryModelConfig(),
  wenetCtc: SherpaOnnxOfflineWenetCtcModelConfig =
    sherpaOnnxOfflineWenetCtcModelConfig(),
  omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig =
    sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
  medasr: SherpaOnnxOfflineMedAsrCtcModelConfig =
    sherpaOnnxOfflineMedAsrCtcModelConfig(),
  funasrNano: SherpaOnnxOfflineFunASRNanoModelConfig =
    sherpaOnnxOfflineFunASRNanoModelConfig(),
  fireRedAsrCtc: SherpaOnnxOfflineFireRedAsrCtcModelConfig =
    sherpaOnnxOfflineFireRedAsrCtcModelConfig(),
  qwen3Asr: SherpaOnnxOfflineQwen3ASRModelConfig =
    sherpaOnnxOfflineQwen3ASRModelConfig(),
  cohereTranscribe: SherpaOnnxOfflineCohereTranscribeModelConfig =
    sherpaOnnxOfflineCohereTranscribeModelConfig()
) -> SherpaOnnxOfflineModelConfig {
  return SherpaOnnxOfflineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    nemo_ctc: nemoCtc,
    whisper: whisper,
    tdnn: tdnn,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    telespeech_ctc: toCPointer(teleSpeechCtc),
    sense_voice: senseVoice,
    moonshine: moonshine,
    fire_red_asr: fireRedAsr,
    dolphin: dolphin,
    zipformer_ctc: zipformerCtc,
    canary: canary,
    wenet_ctc: wenetCtc,
    omnilingual: omnilingual,
    medasr: medasr,
    funasr_nano: funasrNano,
    fire_red_asr_ctc: fireRedAsrCtc,
    qwen3_asr: qwen3Asr,
    cohere_transcribe: cohereTranscribe
  )
}

func sherpaOnnxOfflineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOfflineModelConfig,
  lmConfig: SherpaOnnxOfflineLMConfig = sherpaOnnxOfflineLMConfig(),
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOfflineRecognizerConfig {
  return SherpaOnnxOfflineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    lm_config: lmConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hr: hr
  )
}

class SherpaOnnxOfflineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  let result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _timestamps: [Float] = {
    guard let p = result.pointee.timestamps else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _durations: [Float] = {
    guard let p = result.pointee.durations else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _lang: String = {
    guard let cstr = result.pointee.lang else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _emotion: String = {
    guard let cstr = result.pointee.emotion else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _event: String = {
    guard let cstr = result.pointee.event else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _segmentTimestamps: [Float] = {
    guard let p = result.pointee.segment_timestamps else { return [] }
    return (0..<result.pointee.segment_count).map { p[Int($0)] }
  }()

  private lazy var _segmentDurations: [Float] = {
    guard let p = result.pointee.segment_durations else { return [] }
    return (0..<result.pointee.segment_count).map { p[Int($0)] }
  }()

  private lazy var _segmentTexts: [String] = {
    guard let arr = result.pointee.segment_texts_arr else { return [] }
    return (0..<result.pointee.segment_count).compactMap { idx -> String? in
      guard let ptr = arr[Int(idx)] else { return nil }
      return String(cString: ptr)
    }
  }()

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  var text: String { _text }
  var count: Int { Int(result.pointee.count) }
  var timestamps: [Float] { _timestamps }

  // Non-empty for TDT models. Empty for all other non-TDT models
  var durations: [Float] { _durations }

  // For SenseVoice models, it can be zh, en, ja, yue, ko
  // where zh is for Chinese
  // en is for English
  // ja is for Japanese
  // yue is for Cantonese
  // ko is for Korean
  var lang: String { _lang }

  // for SenseVoice models
  var emotion: String { _emotion }

  // for SenseVoice models
  var event: String { _event }

  // Segment-level timestamps (for Whisper with segment timestamps enabled)
  var segmentCount: Int { Int(result.pointee.segment_count) }
  var segmentTimestamps: [Float] { _segmentTimestamps }
  var segmentDurations: [Float] { _segmentDurations }
  var segmentTexts: [String] { _segmentTexts }

  init(result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizerResult(result)
  }
}

class SherpaOnnxOfflineRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer

  init(
    config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>
  ) {
    guard let ptr = SherpaOnnxCreateOfflineRecognizer(config) else {
      fatalError("Failed to create SherpaOnnxOfflineRecognizer")
    }
    self.recognizer = ptr
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  func decode(samples: [Float], sampleRate: Int = 16_000) -> SherpaOnnxOfflineRecongitionResult {
    let stream = createStream()
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate)
    decode(stream: stream)
    return getResult(stream: stream)
  }

  func setConfig(config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) {
    SherpaOnnxOfflineRecognizerSetConfig(recognizer, config)
  }

  func createStream() -> SherpaOnnxOfflineStreamWrapper {
    guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
      fatalError("Failed to create offline stream")
    }

    return SherpaOnnxOfflineStreamWrapper(stream: stream)
  }

  func decode(stream: SherpaOnnxOfflineStreamWrapper) {
    SherpaOnnxDecodeOfflineStream(recognizer, stream.stream)
  }

  func getResult(stream: SherpaOnnxOfflineStreamWrapper) -> SherpaOnnxOfflineRecongitionResult {
    guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream.stream) else {
      fatalError("Failed to get offline recognition result")
    }

    return SherpaOnnxOfflineRecongitionResult(result: resultPtr)
  }
}

class SherpaOnnxOfflineStreamWrapper {
  let stream: OpaquePointer

  init(stream: OpaquePointer) {
    self.stream = stream
  }

  deinit {
    SherpaOnnxDestroyOfflineStream(stream)
  }

  func setOption(key: String, value: String) {
    SherpaOnnxOfflineStreamSetOption(stream, toCPointer(key), toCPointer(value))
  }

  func acceptWaveform(samples: [Float], sampleRate: Int = 16_000) {
    SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))
  }
}

func sherpaOnnxSileroVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 512,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxSileroVadModelConfig {
  return SherpaOnnxSileroVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

func sherpaOnnxTenVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 256,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxTenVadModelConfig {
  return SherpaOnnxTenVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

func sherpaOnnxVadModelConfig(
  sileroVad: SherpaOnnxSileroVadModelConfig = sherpaOnnxSileroVadModelConfig(),
  sampleRate: Int32 = 16000,
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  tenVad: SherpaOnnxTenVadModelConfig = sherpaOnnxTenVadModelConfig()
) -> SherpaOnnxVadModelConfig {
  return SherpaOnnxVadModelConfig(
    silero_vad: sileroVad,
    sample_rate: sampleRate,
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    ten_vad: tenVad
  )
}

class SherpaOnnxCircularBufferWrapper {
  private let buffer: OpaquePointer

  init(capacity: Int) {
    guard let ptr = SherpaOnnxCreateCircularBuffer(Int32(capacity)) else {
      fatalError("Failed to create SherpaOnnxCircularBuffer")
    }
    self.buffer = ptr
  }

  deinit {
    SherpaOnnxDestroyCircularBuffer(buffer)
  }

  func push(samples: [Float]) {
    guard !samples.isEmpty else { return }
    SherpaOnnxCircularBufferPush(buffer, samples, Int32(samples.count))
  }

  func get(startIndex: Int, n: Int) -> [Float] {
    guard startIndex >= 0 else { return [] }
    guard n > 0 else { return [] }

    guard let ptr = SherpaOnnxCircularBufferGet(buffer, Int32(startIndex), Int32(n)) else {
      return []
    }
    defer { SherpaOnnxCircularBufferFree(ptr) }

    return Array(UnsafeBufferPointer(start: ptr, count: n))
  }

  func pop(n: Int) {
    guard n > 0 else { return }
    SherpaOnnxCircularBufferPop(buffer, Int32(n))
  }

  func size() -> Int {
    return Int(SherpaOnnxCircularBufferSize(buffer))
  }

  func reset() {
    SherpaOnnxCircularBufferReset(buffer)
  }
}

class SherpaOnnxSpeechSegmentWrapper {
  private let p: UnsafePointer<SherpaOnnxSpeechSegment>

  init(p: UnsafePointer<SherpaOnnxSpeechSegment>) {
    self.p = p
  }

  deinit {
    SherpaOnnxDestroySpeechSegment(p)
  }

  var start: Int {
    Int(p.pointee.start)
  }

  var n: Int {
    Int(p.pointee.n)
  }

  lazy var samples: [Float] = {
    Array(UnsafeBufferPointer(start: p.pointee.samples, count: n))
  }()
}

class SherpaOnnxVoiceActivityDetectorWrapper {
  /// A pointer to the underlying counterpart in C
  private let vad: OpaquePointer

  init(config: UnsafePointer<SherpaOnnxVadModelConfig>, buffer_size_in_seconds: Float) {
    guard let vad = SherpaOnnxCreateVoiceActivityDetector(config, buffer_size_in_seconds) else {
      fatalError("SherpaOnnxCreateVoiceActivityDetector returned nil")
    }
    self.vad = vad
  }

  deinit {
    SherpaOnnxDestroyVoiceActivityDetector(vad)
  }

  func acceptWaveform(samples: [Float]) {
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(samples.count))
  }

  func isEmpty() -> Bool {
    return SherpaOnnxVoiceActivityDetectorEmpty(vad) == 1
  }

  func isSpeechDetected() -> Bool {
    return SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
  }

  func pop() {
    SherpaOnnxVoiceActivityDetectorPop(vad)
  }

  func clear() {
    SherpaOnnxVoiceActivityDetectorClear(vad)
  }

  func front() -> SherpaOnnxSpeechSegmentWrapper {
    guard let p = SherpaOnnxVoiceActivityDetectorFront(vad) else {
      fatalError("SherpaOnnxVoiceActivityDetectorFront returned nil")
    }
    return SherpaOnnxSpeechSegmentWrapper(p: p)
  }

  func reset() {
    SherpaOnnxVoiceActivityDetectorReset(vad)
  }

  func flush() {
    SherpaOnnxVoiceActivityDetectorFlush(vad)
  }
}

// offline tts
