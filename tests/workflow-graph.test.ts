import { describe, expect, it } from "vitest";

import { parseWorkflowCartridge } from "../src/workflows/parser.js";
import { compileGraph } from "../src/workflows/graph.js";

function compileFromHtml(html: string) {
  return compileGraph(parseWorkflowCartridge({ html }));
}

describe("workflow graph compilation", () => {
  it("rejects goto edges that target a vertex inside a loop body from outside the loop", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="goto-into-loop" name="goto-into-loop" version="0.1.0">
        <h2-flow>
          <h2-branch id="outside-branch" on="artifact.route.status">
            <h2-case value="enter" goto="body-script"></h2-case>
            <h2-default goto="exit-script"></h2-default>
          </h2-branch>
          <h2-loop id="loop" max="2">
            <h2-script id="body-script" uses="test.pass"></h2-script>
          </h2-loop>
          <h2-script id="exit-script" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).toThrow(/goto from outside a loop into the loop body/);
  });

  it("accepts a branch case that uses continue to target an immediate enclosing loop", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="continue-immediate" name="continue-immediate" version="0.1.0">
        <h2-flow>
          <h2-loop id="outer" max="3">
            <h2-script id="step" uses="test.pass"></h2-script>
            <h2-branch id="route" on="artifact.flag.status">
              <h2-case value="again" continue="outer"></h2-case>
              <h2-default goto="exit-script"></h2-default>
            </h2-branch>
          </h2-loop>
          <h2-script id="exit-script" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).not.toThrow();
  });

  it("accepts a branch in an inner loop that continues to an outer enclosing loop", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="continue-outer" name="continue-outer" version="0.1.0">
        <h2-flow>
          <h2-loop id="outer" max="2">
            <h2-loop id="inner" max="2">
              <h2-branch id="route" on="artifact.flag.status">
                <h2-case value="restart-outer" continue="outer"></h2-case>
                <h2-default goto="exit-script"></h2-default>
              </h2-branch>
            </h2-loop>
          </h2-loop>
          <h2-script id="exit-script" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).not.toThrow();
  });

  it("rejects continue that targets a loop the branch is not nested under", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="continue-unrelated" name="continue-unrelated" version="0.1.0">
        <h2-flow>
          <h2-loop id="loop-a" max="2">
            <h2-script id="loop-a-step" uses="test.pass"></h2-script>
          </h2-loop>
          <h2-loop id="loop-b" max="2">
            <h2-branch id="route" on="artifact.flag.status">
              <h2-case value="restart-a" continue="loop-a"></h2-case>
              <h2-default goto="exit-script"></h2-default>
            </h2-branch>
          </h2-loop>
          <h2-script id="exit-script" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).toThrow(/not in the branch's enclosing loop chain/);
  });

  it("rejects branch edges that escape a parallel branch to a vertex outside the parallel scope", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="parallel-escape" name="parallel-escape" version="0.1.0">
        <h2-flow>
          <h2-parallel id="workers">
            <h2-sequence>
              <h2-script id="worker-a" uses="test.pass"></h2-script>
              <h2-branch id="worker-a-route" on="artifact.flag.status">
                <h2-case value="bail" goto="outside-target"></h2-case>
                <h2-default goto="worker-a-done"></h2-default>
              </h2-branch>
              <h2-script id="worker-a-done" uses="test.pass"></h2-script>
            </h2-sequence>
            <h2-sequence>
              <h2-script id="worker-b" uses="test.pass"></h2-script>
            </h2-sequence>
          </h2-parallel>
          <h2-script id="outside-target" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).toThrow(/parallel.*escape|parallel_branch_escape/);
  });

  it("accepts branches inside a parallel branch that target siblings within the same parallel branch", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="parallel-inner-branch" name="parallel-inner-branch" version="0.1.0">
        <h2-flow>
          <h2-parallel id="workers">
            <h2-sequence>
              <h2-script id="worker-a" uses="test.pass"></h2-script>
              <h2-branch id="worker-a-route" on="artifact.flag.status">
                <h2-case value="next" goto="worker-a-next"></h2-case>
                <h2-default goto="worker-a-done"></h2-default>
              </h2-branch>
              <h2-script id="worker-a-next" uses="test.pass"></h2-script>
              <h2-script id="worker-a-done" uses="test.pass"></h2-script>
            </h2-sequence>
            <h2-sequence>
              <h2-script id="worker-b" uses="test.pass"></h2-script>
            </h2-sequence>
          </h2-parallel>
          <h2-script id="after-parallel" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).not.toThrow();
  });

  it("rejects non-loop cycles formed by goto", () => {
    expect(() => compileFromHtml(`
      <h2-workflow id="invalid-cycle" name="invalid-cycle" version="0.1.0">
        <h2-flow>
          <h2-script id="step-a" uses="test.pass"></h2-script>
          <h2-branch id="route" on="artifact.flag.status">
            <h2-case value="loop" goto="step-a"></h2-case>
            <h2-default goto="step-b"></h2-default>
          </h2-branch>
          <h2-script id="step-b" uses="test.pass"></h2-script>
        </h2-flow>
      </h2-workflow>
    `)).toThrow(/cycle that is not closed by a loop back-edge/);
  });
});
