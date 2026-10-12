import localUnitTest from './LocalUnit.test';
import v131Tests from './V131.test';

export default function testsuite() {
  localUnitTest();
  v131Tests();
}
