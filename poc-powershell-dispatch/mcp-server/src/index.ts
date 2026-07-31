import { app } from "@azure/functions";

app.setup({
  enableHttpStream: true,
});

import "./functions/submitWipeRequest.js";
import "./functions/getWipeStatus.js";
