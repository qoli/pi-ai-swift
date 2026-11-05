// The same predicates judge both implementations; generated prose is never compared byte-for-byte.
export function judge(spec, observation) {
  const turns = observation.turns ?? [];
  const checks = {};
  checks.executed = turns.length === spec.turns.length;
  if (spec.cancelAfterFirstDelta) {
    checks.cancelledAfterOutput = observation.cancelled === true && turns[0]?.textDeltas > 0;
    checks.noSuccessfulCompletionAfterCancel = !turns[0]?.completed;
  } else {
    checks.noFailure = !observation.failure;
    checks.completeStreams = turns.every(t => t.started && t.completed && t.snapshot);
    checks.usage = turns.every(t => t.inputTokens > 0 && t.outputTokens > 0);
    checks.eventOrder = turns.every(t => t.orderValid);
    if (spec.expectedProtocolID) checks.protocolDispatch = observation.protocolID === spec.expectedProtocolID;
    for (const [index, turn] of spec.turns.entries()) {
      const actual = turns[index];
      if (turn.expectText) checks[`turn${index}.text`] = actual?.text?.includes(turn.expectText) === true;
      if (turn.expectWords) checks[`turn${index}.imageDescription`] = turn.expectWords.every(word=>actual?.text?.toLowerCase().includes(word));
      if (spec.structuredOutput) {
        let value;
        try { value=JSON.parse(actual?.text); } catch {}
        checks[`turn${index}.structuredSchema`] = value?.result===42 && Object.keys(value).length===1;
      }
      if (turn.expectTool) {
        checks[`turn${index}.toolLifecycle`] = actual?.toolStarts > 0 && actual?.toolEnds > 0;
        checks[`turn${index}.toolTermination`] = actual?.stopReason === "toolUse";
        checks[`turn${index}.toolArguments`] = actual?.calls?.some(call =>
          Boolean(call.id) && call.name === "math_operation" && call.arguments?.a === 15 && call.arguments?.b === 27
          && call.arguments?.operation === "add") === true;
      }
    }
    if (spec.expectReasoning !== undefined) {
      const observed = turns.some(t => t.reasoningDeltas > 0 || t.reasoningTokens > 0);
      checks.reasoningMode = observed === spec.expectReasoning;
    }
  }
  return { passed: Object.values(checks).every(Boolean), checks };
}

export function safeObservation(observation) {
  return {
    cancelled: observation.cancelled ?? false,
    observationTimeout: observation.observationTimeout ?? false,
    protocolID: observation.protocolID,
    network: observation.network,
    hostRefreshRequired: observation.hostRefreshRequired ?? false,
    failure: observation.failure,
    turns: (observation.turns ?? []).map(({text, calls, ...safe}) => safe),
  };
}

export function compare(spec, swift, typescript) {
  const a = judge(spec, swift), b = judge(spec, typescript);
  return {
    status: typescript.failure?.code?.endsWith('_unrepresented') ? "interface_gap"
      : typescript.hostRefreshRequired ? "host_refresh_required"
      : swift.observationTimeout || typescript.observationTimeout ? "observation_timeout"
      : a.passed && b.passed ? "passed" : b.passed ? "swift_failure"
      : a.passed ? "reference_failure" : "both_failed",
    swift: { ...a, observation: safeObservation(swift) },
    typescript: { ...b, observation: safeObservation(typescript) },
  };
}
