/**
 * Middle of the WideProbe inheritance chain. See WideProbeRoot for why the chain exists.
 */
component extends="models.WideProbeRoot" {

	variables.baseA = "base-a";
	variables.baseB = "base-b";
	variables.baseC = 0;

	function init() {
		super.init();
		variables.baseC = 2;
		return this;
	}

	function getBaseA() {
		return variables.baseA;
	}

	function getBaseB() {
		return variables.baseB;
	}

	function getBaseC() {
		return variables.baseC;
	}

	function touchBase() {
		variables.baseC = variables.baseC + 1;
		return this;
	}

	private function baseHelper() {
		return variables.baseA & variables.baseB & variables.baseC;
	}

}
