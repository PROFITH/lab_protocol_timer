/// What happens in a calibration, second by second. The technician does it
/// alone, before the participants arrive or after they leave: the sensors
/// are already recording, inside the dodecahedron (or a rigid box).
enum CalibrationStepKind {
  /// Face 1 up, getting ready for the first knocks (10 s; the 2-min still
  /// start was dropped in 1.3.1).
  still,

  /// Three sharp knocks on the table: a common mark in every sensor.
  knock,

  /// One face up, still.
  face,
}

class CalibrationStep {
  const CalibrationStep(this.kind, this.startSecond, this.seconds, {this.face});

  final CalibrationStepKind kind;
  final int startSecond;
  final int seconds;

  /// Face up during the step (1 during the still phase and the knocks at
  /// the start; the last face at the end).
  final int? face;

  int get endSecond => startSecond + seconds;
}

class CalibrationProgram {
  CalibrationProgram({
    this.faces = 12,
    int? faceSeconds,
    this.stillSeconds = 10,
    this.knockSeconds = 10,
  }) : faceSeconds = faceSeconds ?? (faces == 12 ? 40 : 60) {
    var t = 0;
    void add(CalibrationStepKind kind, int seconds, {int? face}) {
      steps.add(CalibrationStep(kind, t, seconds, face: face));
      t += seconds;
    }

    if (stillSeconds > 0) add(CalibrationStepKind.still, stillSeconds, face: 1);
    add(CalibrationStepKind.knock, knockSeconds, face: 1);
    for (var f = 1; f <= faces; f++) {
      add(CalibrationStepKind.face, this.faceSeconds, face: f);
    }
    add(CalibrationStepKind.knock, knockSeconds, face: faces);
    totalSeconds = t;
  }

  /// 12 for the dodecahedron, 6 for a rigid box.
  final int faces;
  final int faceSeconds;
  final int stillSeconds;
  final int knockSeconds;
  final List<CalibrationStep> steps = [];
  late final int totalSeconds;

  /// Beeps before each change of face, one per second.
  static const warningBeeps = 3;

  /// Step running [elapsed] seconds after the start, or null once it is over.
  CalibrationStep? stepAt(double elapsed) {
    for (final s in steps) {
      if (elapsed < s.endSecond) return s;
    }
    return null;
  }

  int indexOf(CalibrationStep step) => steps.indexOf(step);

  /// The step after [step], or null.
  CalibrationStep? next(CalibrationStep step) {
    final i = steps.indexOf(step);
    return i < 0 || i + 1 >= steps.length ? null : steps[i + 1];
  }

  /// Instruction for the technician during [step].
  String instruction(CalibrationStep step) => switch (step.kind) {
        CalibrationStepKind.still =>
          'Dodecaedro sobre la mesa con la cara 1 hacia arriba. Prepárate: al último pitido, tres golpes secos.',
        CalibrationStepKind.knock => identical(step, _firstKnock)
            ? 'Con la cara 1 hacia arriba, da tres golpes secos con el dodecaedro sobre la mesa y déjalo quieto.'
            : 'Da tres golpes secos con el dodecaedro sobre la mesa. Después ya puedes sacar los sensores.',
        CalibrationStepKind.face =>
          'Cara ${step.face} hacia arriba. Quieto, sin tocar la mesa.',
      };

  CalibrationStep get _firstKnock =>
      steps.firstWhere((s) => s.kind == CalibrationStepKind.knock);

  /// What is said when [step] starts.
  String announcement(CalibrationStep step) => switch (step.kind) {
        CalibrationStepKind.still => 'Calibración. Cara 1 arriba. En $stillSeconds segundos, tres golpes secos.',
        CalibrationStepKind.knock => 'Tres golpes secos.',
        CalibrationStepKind.face => 'Cara ${step.face}.',
      };
}
