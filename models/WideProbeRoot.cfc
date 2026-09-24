/**
 * Bottom of the WideProbe inheritance chain.
 *
 * The chain exists so that constructing a WideProbe makes ColdFusion resolve three
 * components, not one. Resolving a parent goes through the same name-resolution path as
 * the child, so a deeper chain spends more time there.
 */
component {

	variables.rootA = "root-a";
	variables.rootB = 0;

	function init() {
		variables.rootB = 1;
		return this;
	}

	function getRootA() {
		return variables.rootA;
	}

	function getRootB() {
		return variables.rootB;
	}

	function touchRoot() {
		variables.rootB = variables.rootB + 1;
		return this;
	}

	private function rootHelper() {
		return variables.rootA & variables.rootB;
	}

}
