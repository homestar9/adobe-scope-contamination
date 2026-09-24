/**
 * Torture probe model (P1 outer pair). Its pseudo-constructor constructs SlowLeafA, which
 * adds SlowLeafA's lock to this thread's held set on the per-class jar. A concurrent direct
 * construction of SlowLeafA therefore has to wait for Outer to finish (expected serial).
 * Outer itself does not sleep, so both sides take about one sleep period on their own.
 */
component {

	variables.leaf = createObject( "component", "models.torture.SlowLeafA" );

}
