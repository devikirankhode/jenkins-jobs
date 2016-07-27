evaluate(new File("${WORKSPACE}/common.groovy"))

job("clusterator-create") {
  description "Create a set number of clusters in the deis leasable project. This job runs Monday-Friday at 7AM."

  logRotator {
    daysToKeep defaults.daysToKeep
  }

  triggers {
    cron('0 7 1 * 1-5')
  }

  parameters {
    stringParam('NUMBER_OF_CLUSTERS', '10', 'Number of clusters to create at 1 time')
    stringParam('NUM_NODES', '5', 'Number of nodes in each cluster')
    stringParam('MACHINE_TYPE', 'n1-standard-4', 'Node type')
    stringParam('VERSION', '1.2.5', 'The version of kubernetes to use.')
  }

  wrappers {
    timestamps()
    colorizeOutput 'xterm'
    credentialsBinding {
      string("GCLOUD_CREDENTIALS", "15122437-45b8-48ac-bb84-652394c8a927")
    }
  }

  steps {
    shell """
      #!/usr/bin/env bash

      set -eo pipefail
      docker run -e GCLOUD_CREDENTIALS=\${GCLOUD_CREDENTIALS} quay.io/deisci/clusterator:git-b1810a5
    """.stripIndent().trim()
  }
}

job("clusterator-delete") {
  description "Clean up clusters in the deis leasable project. This job runs Monday-Friday at 7PM."

  logRotator {
    daysToKeep defaults.daysToKeep
  }

  triggers {
    cron('0 19 1 * 1-5')
  }

  wrappers {
    timestamps()
    colorizeOutput 'xterm'
    credentialsBinding {
      string("GCLOUD_CREDENTIALS", "15122437-45b8-48ac-bb84-652394c8a927")
    }
  }

  steps {
    shell """
      #!/usr/bin/env bash

      set -eo pipefail
      docker run -e GCLOUD_CREDENTIALS=\${GCLOUD_CREDENTIALS} quay.io/deisci/clusterator:git-b1810a5 delete
    """.stripIndent().trim()
  }
}