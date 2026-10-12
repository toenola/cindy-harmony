import localUnitTest from './LocalUnit.test';
import v131Tests from './V131.test';
import v132DefaultsTests from './V132Defaults.test';
import v132InteractionTests from './V132Interactions.test';
import v132QueueTests from './V132Queue.test';
import v132SessionTests from './V132Session.test';
import v132LinkTests from './V132Link.test';

export default function testsuite() {
  localUnitTest();
  v131Tests();
  v132DefaultsTests();
  v132InteractionTests();
  v132QueueTests();
  v132SessionTests();
  v132LinkTests();
}
