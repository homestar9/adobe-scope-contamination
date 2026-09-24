/**
 * A heavier transient for hotfix benchmarks, roughly the weight of a Quick entity.
 *
 * ConstructionProbe is only three methods with no parent, which may be too small to show a
 * cost that lands on every component ColdFusion resolves. This one has a two-level extends
 * chain and around fifteen methods, so it carries more metadata and takes longer to build.
 *
 * Keeps the same setValue/getValue contract as ConstructionProbe so the caller's checksum
 * check still catches a contaminated instance.
 */
component extends="models.WideProbeBase" {

	variables.value  = 0;
	variables.propA  = "alpha";
	variables.propB  = "bravo";
	variables.propC  = "charlie";
	variables.propD  = "delta";
	variables.propE  = 0;
	variables.propF  = [];
	variables.propG  = {};

	function init() {
		super.init();
		variables.propE = 3;
		variables.propF = [ 1, 2, 3 ];
		variables.propG = { "a" : 1, "b" : 2 };
		return this;
	}

	function setValue( required numeric value ) {
		variables.value = arguments.value;
		return this;
	}

	numeric function getValue() {
		return variables.value;
	}

	function getPropA() {
		return variables.propA;
	}

	function getPropB() {
		return variables.propB;
	}

	function getPropC() {
		return variables.propC;
	}

	function getPropD() {
		return variables.propD;
	}

	function getPropE() {
		return variables.propE;
	}

	function getPropF() {
		return variables.propF;
	}

	function getPropG() {
		return variables.propG;
	}

	function describe() {
		return variables.propA & "|" & variables.propB & "|" & variables.propC;
	}

	private function wideHelper() {
		return variables.propE + arrayLen( variables.propF ) + structCount( variables.propG );
	}

}
