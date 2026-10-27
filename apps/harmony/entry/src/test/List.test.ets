import localUnitTest from './LocalUnit.test';
import v131Tests from './V131.test';
import v132DefaultsTests from './V132Defaults.test';
import v132InteractionTests from './V132Interactions.test';
import v132QueueTests from './V132Queue.test';
import v132SessionTests from './V132Session.test';
import v132LinkTests from './V132Link.test';
import v132HistoryTests from './V132History.test';
import v132RenderingTests from './V132Rendering.test';
import v132PresentationTests from './V132Presentation.test';
import v132DeletionTests from './V132Deletion.test';
import v132DeliveryTests from './V132Delivery.test';
import v133RichAnswerTests from './V133RichAnswer.test';
import v133SpeedTests from './V133Speed.test';
import v133PresentationTests from './V133Presentation.test';

export default function testsuite() {
  localUnitTest();
  v131Tests();
  v132DefaultsTests();
  v132InteractionTests();
  v132QueueTests();
  v132SessionTests();
  v132LinkTests();
  v132HistoryTests();
  v132RenderingTests();
  v132PresentationTests();
  v132DeletionTests();
  v132DeliveryTests();
  v133RichAnswerTests();
  v133SpeedTests();
  v133PresentationTests();
}
