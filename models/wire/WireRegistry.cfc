/**
 * Wire probe singleton, shared by every WireProbe the way Quick entities share singletons such
 * as Str@str and the CacheBox metadata cache. It hands out per-class settings from one cached
 * struct; callers copy what they need into their own variables scope.
 */
component singleton {

	function init() {
		variables.settingsByKind = {};
		return this;
	}

	struct function settingsFor( required string kind ) {
		if ( !structKeyExists( variables.settingsByKind, arguments.kind ) ) {
			variables.settingsByKind[ arguments.kind ] = { "kind" : arguments.kind, "label" : "probe-" & lCase( arguments.kind ) };
		}
		return variables.settingsByKind[ arguments.kind ];
	}

}
