/**
 * Small, database-free endpoints for comparing CFC construction performance
 * with and without an Adobe hotfix.
 */
component extends="coldbox.system.RestHandler" {

	/**
	 * GET /benchmark/quickconstruct?count=25
	 *
	 * Constructs a fresh Quick entity AND its query builder every iteration,
	 * without touching the database: metadata duplication in metadataInspection,
	 * QuickBuilder/QuickQB creation, and column formatter setup. This is the ORM
	 * construction path, measured without database time.
	 */
	function quickConstruct( event, rc, prc ) {
		var iterations = normalizeCount( rc );
		var checksum   = 0;

		for ( var i = 1; i <= iterations; i++ ) {
			var entity  = getInstance( "AlphaChild" );
			var builder = entity.newQuery();
			// Contributes i only when the fresh builder's table matches its
			// entity's table, so the checksum doubles as a correctness check.
			checksum += builder.getQB().getTableName() == entity.tableName() ? i : 0;
		}

		return benchmarkResult( event, "quickconstruct", "entity+builder", iterations, checksum );
	}

	/**
	 * GET /benchmark/engine
	 *
	 * Reports which ColdFusion build, JVM, and update jars this server is running, plus
	 * the jar each patched class was actually loaded from.
	 *
	 * The code source is the part that matters. Dropping a jar into lib/updates is assumed
	 * to override the shipped class, but nothing guarantees which update jar wins. If both
	 * benchmark test servers load TemplateProxyFactory from the same jar then they are the same
	 * server and every number collected from them is noise. The harness calls this before
	 * measuring and refuses to run if the two test servers report the same source.
	 */
	function engine( event, rc, prc ) {
		var system  = createObject( "java", "java.lang.System" );
		var rootDir = system.getProperty( "coldfusion.rootDir", "" );
		var updates = [];

		// Lucee and BoxLang have no coldfusion.rootDir and no Adobe classes; every Adobe-only
		// field below degrades to "unavailable" so the same endpoint identifies any engine.
		if ( isNull( rootDir ) ) { rootDir = ""; }

		if ( len( rootDir ) && directoryExists( rootDir & "/lib/updates" ) ) {
			updates = directoryList(
				path   = rootDir & "/lib/updates",
				filter = "*.jar",
				listInfo = "name"
			);
		}

		return {
			"productName"    : server.coldfusion.keyExists( "productName" ) ? server.coldfusion.productName : "ColdFusion",
			"productVersion" : server.coldfusion.productVersion,
			"productLevel"   : server.coldfusion.keyExists( "productLevel" ) ? server.coldfusion.productLevel : "",
			"engineVersion"  : server.keyExists( "lucee" ) ? server.lucee.version : ( server.keyExists( "boxlang" ) ? server.boxlang.version : server.coldfusion.productVersion ),
			"jvmVersion"     : system.getProperty( "java.version" ),
			"jvmVendor"      : system.getProperty( "java.vendor" ),
			"rootDir"        : rootDir,
			"updateJars"     : updates,
			"classSources"   : classSources(),
			"constructionLocks" : constructionLocks(),
			"implicitTemps"  : implicitTemps()
		};
	}

	/**
	 * Behavioral fingerprint of Adobe's fourth hotfix, no reflection needed: build inline
	 * literals inside conditional expressions in this (singleton) handler and report where the
	 * compiler's temporaries (`___IMPLICITARRYSTRUCTVAR<n>`) ended up. For that shape (and only
	 * that shape; a literal in a plain statement is declared as a local by the compiler) unfixed
	 * engines put the temporary in the component's variables scope; v4 keeps it in the function's
	 * local scope. Lucee and BoxLang have no such temporaries, so both lists are empty there.
	 */
	private struct function implicitTemps() {
		var out = { "inVariables" : [], "inLocal" : [], "design" : "unknown" };
		try {
			var never = variables.keyExists( "implicitTempsNeverSet" );
			var s = never ? {} : { "a" : 1, "b" : { "c" : [ 1, 2 ] } };
			var a = never ? [] : [ { "d" : 4 }, 5 ];
			var n = implicitTempsEcho( never ? {} : { "e" : 6 } );
			for ( var key in structKeyArray( variables ) ) {
				if ( left( key, 11 ) == "___IMPLICIT" ) out.inVariables.append( key );
			}
			for ( var key in structKeyArray( local ) ) {
				if ( left( key, 11 ) == "___IMPLICIT" ) out.inLocal.append( key );
			}
			out.design = out.inVariables.len() ? "shared-variables" : ( out.inLocal.len() ? "function-local" : "none" );
		} catch ( any e ) {
			out.design = "unavailable: " & e.message;
		}
		return out;
	}

	private numeric function implicitTempsEcho( required struct s ) {
		return structCount( arguments.s );
	}

	/**
	 * Where the classloader actually found each class the hotfix replaces.
	 *
	 * Any class that fails to resolve is reported as "unavailable" rather than throwing,
	 * so a single missing class cannot take down the whole preflight check.
	 */
	private struct function classSources() {
		var targets = [
			"coldfusion.runtime.TemplateProxyFactory",
			"coldfusion.runtime.TemplateProxy",
			"coldfusion.runtime.UDFMethod",
			"coldfusion.runtime.Closure",
			// The four classes above are the ones Adobe's first hotfix replaced. The two below
			// were patched by earlier experimental builds; on the current test servers they resolve
			// to the stock cfusion.jar.
			"coldfusion.runtime.ObjectDuplicator",
			"coldfusion.util.CaseInsensitiveMap",
			// Adobe's fourth hotfix (v4) ships ONLY NeoPageContext: compiler temporaries for inline
			// struct/array literals are kept in the function's local scope instead of the component's
			// variables scope. On the v4 test server this must resolve to the hf202300-4232227.jar
			// overlay; on every other test server it resolves to chf20230023.jar.
			"coldfusion.runtime.NeoPageContext"
		];
		var sources = {};

		for ( var target in targets ) {
			try {
				sources[ target ] = createObject( "java", target )
					.getClass()
					.getProtectionDomain()
					.getCodeSource()
					.getLocation()
					.toString();
			} catch ( any e ) {
				sources[ target ] = "unavailable: " & e.message;
			}
		}

		return sources;
	}

	/**
	 * Runtime fingerprint of the construction lock design, read straight off
	 * TemplateProxyFactory's static fields, so a test server proves what it is rather than
	 * being trusted by filename:
	 *   v1 hotfix : CONSTRUCTION_LOCK (one java.lang.Object monitor)              -> "global"
	 *   v3 hotfix : CLASS_CONSTRUCTION_LOCKS (ConcurrentHashMap of ReentrantLock) -> "perclass"
	 *   stock     : neither                                                        -> "none"
	 * mapSize is how many distinct CFC paths have been constructed so far on the v3
	 * design (the map never evicts), which the endurance test and lock stress test scripts watch.
	 */
	private struct function constructionLocks() {
		var out = { "design" : "unknown", "hasGlobalLock" : false, "hasPerClassMap" : false, "mapSize" : -1 };
		try {
			var cls   = createObject( "java", "coldfusion.runtime.TemplateProxyFactory" ).getClass();
			var names = [];
			for ( var f in cls.getDeclaredFields() ) {
				names.append( f.getName() );
			}
			out.hasGlobalLock  = names.find( "CONSTRUCTION_LOCK" ) > 0;
			out.hasPerClassMap = names.find( "CLASS_CONSTRUCTION_LOCKS" ) > 0;
			if ( out.hasPerClassMap ) {
				try {
					var field = cls.getDeclaredField( "CLASS_CONSTRUCTION_LOCKS" );
					field.setAccessible( true );
					out.mapSize = field.get( javaCast( "null", "" ) ).size();
				} catch ( any inner ) {
					out.mapSize = -1;
				}
			}
			out.design = out.hasPerClassMap ? "perclass" : ( out.hasGlobalLock ? "global" : "none" );
		} catch ( any e ) {
			out.design = "unavailable: " & e.message;
		}
		return out;
	}

	private numeric function normalizeCount( required struct rc ) {
		var requested = arguments.rc.keyExists( "count" ) ? int( val( arguments.rc.count ) ) : 25;
		return max( 1, min( 500, requested ) );
	}

	private struct function benchmarkResult(
		required any event,
		required string benchmark,
		required string shape,
		required numeric iterations,
		required numeric checksum,
		struct extra = {}
	) {
		var expected = ( arguments.iterations * ( arguments.iterations + 1 ) ) / 2;
		var valid    = arguments.checksum == expected;

		if ( !valid ) {
			arguments.event.setHTTPHeader( statusCode = 500, statusText = "Benchmark Checksum Error" );
		}

		var out = {
			"ok"         : valid,
			"benchmark"  : arguments.benchmark,
			"shape"      : arguments.shape,
			"iterations" : arguments.iterations,
			"checksum"   : arguments.checksum,
			"expected"   : expected
		};
		out.append( arguments.extra );
		return out;
	}

}
